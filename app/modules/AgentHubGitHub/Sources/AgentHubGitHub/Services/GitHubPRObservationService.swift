//
//  GitHubPRObservationService.swift
//  AgentHub
//
//  Shared PR/check observation for GitHub surfaces.
//

import Foundation

public enum GitHubPRObservationTarget: Hashable, Sendable {
  case currentBranch(projectPath: String, branchName: String?)
  case pullRequest(projectPath: String, number: Int)

  public var projectPath: String {
    switch self {
    case .currentBranch(let projectPath, _), .pullRequest(let projectPath, _):
      return projectPath
    }
  }

  public var pullRequestNumber: Int? {
    switch self {
    case .currentBranch:
      return nil
    case .pullRequest(_, let number):
      return number
    }
  }

  var key: String {
    switch self {
    case .currentBranch(let projectPath, let branchName):
      return "current|\(projectPath)|\(branchName ?? "")"
    case .pullRequest(let projectPath, let number):
      return "pr|\(projectPath)|\(number)"
    }
  }
}

public enum GitHubPRObservationState: Equatable, Sendable {
  case idle
  case refreshing
  case ready
  case error(String)
  case paused(String)

  public var isRefreshing: Bool {
    if case .refreshing = self { return true }
    return false
  }
}

public struct GitHubCISummary: Equatable, Sendable {
  public let passed: Int
  public let failed: Int
  public let pending: Int
  public let skipped: Int
  public let total: Int

  public init(checks: [GitHubCheckRun]) {
    var passed = 0
    var failed = 0
    var pending = 0
    var skipped = 0

    for check in checks {
      switch check.ciStatus {
      case .success:
        passed += 1
      case .failure:
        failed += 1
      case .pending:
        pending += 1
      case .none:
        skipped += 1
      }
    }

    self.passed = passed
    self.failed = failed
    self.pending = pending
    self.skipped = skipped
    self.total = checks.count
  }

  public var overallStatus: CIStatus {
    if failed > 0 { return .failure }
    if pending > 0 { return .pending }
    if passed > 0 { return .success }
    return .none
  }
}

public struct GitHubPRObservationSnapshot: Equatable, Sendable {
  public let target: GitHubPRObservationTarget
  public let pullRequest: GitHubPullRequest?
  public let checks: [GitHubCheckRun]
  public let ciSummary: GitHubCISummary
  public let state: GitHubPRObservationState
  public let lastRefreshedAt: Date?

  public init(
    target: GitHubPRObservationTarget,
    pullRequest: GitHubPullRequest?,
    checks: [GitHubCheckRun],
    state: GitHubPRObservationState,
    lastRefreshedAt: Date?
  ) {
    self.target = target
    self.pullRequest = pullRequest
    self.checks = checks
    self.ciSummary = GitHubCISummary(checks: checks)
    self.state = state
    self.lastRefreshedAt = lastRefreshedAt
  }

  public static func initial(target: GitHubPRObservationTarget) -> GitHubPRObservationSnapshot {
    GitHubPRObservationSnapshot(
      target: target,
      pullRequest: nil,
      checks: [],
      state: .idle,
      lastRefreshedAt: nil
    )
  }
}

public struct GitHubPRObservationSubscription: Sendable {
  public let id: UUID
  public let updates: AsyncStream<GitHubPRObservationSnapshot>

  public init(id: UUID, updates: AsyncStream<GitHubPRObservationSnapshot>) {
    self.id = id
    self.updates = updates
  }
}

public protocol GitHubPRObservationServiceProtocol: AnyObject, Sendable {
  func subscribe(
    to target: GitHubPRObservationTarget,
    refreshOnSubscribe: Bool
  ) async -> GitHubPRObservationSubscription
  func unsubscribe(subscriptionID: UUID) async
  func refresh(_ target: GitHubPRObservationTarget) async
  func recordActivity(for target: GitHubPRObservationTarget, at: Date) async
}

public extension GitHubPRObservationServiceProtocol {
  func subscribe(to target: GitHubPRObservationTarget) async -> GitHubPRObservationSubscription {
    await subscribe(to: target, refreshOnSubscribe: true)
  }
}

public struct GitHubPRObservationConfiguration: Sendable {
  public var pendingPollInterval: TimeInterval
  public var settledPollInterval: TimeInterval
  public var idleTimeout: TimeInterval
  public var errorBackoff: [TimeInterval]

  public init(
    pendingPollInterval: TimeInterval = 30,
    settledPollInterval: TimeInterval = 120,
    idleTimeout: TimeInterval = 5 * 60,
    errorBackoff: [TimeInterval] = [60, 120, 300]
  ) {
    self.pendingPollInterval = pendingPollInterval
    self.settledPollInterval = settledPollInterval
    self.idleTimeout = idleTimeout
    self.errorBackoff = errorBackoff
  }
}

public actor GitHubPRObservationService: GitHubPRObservationServiceProtocol {
  private struct Entry {
    let target: GitHubPRObservationTarget
    var snapshot: GitHubPRObservationSnapshot
    var lastActivityAt: Date?
    var consecutiveErrorCount = 0
    var isTerminallyPaused = false
    var isRefreshing = false
    var pendingPostRefreshEvaluation = false
    var scheduledRefreshTask: Task<Void, Never>?
    var subscribers: [UUID: AsyncStream<GitHubPRObservationSnapshot>.Continuation] = [:]
  }

  private let service: any GitHubCLIServiceProtocol
  private let configuration: GitHubPRObservationConfiguration
  private var entries: [String: Entry] = [:]
  private var subscriptionKeys: [UUID: String] = [:]

  public init(
    service: any GitHubCLIServiceProtocol = GitHubCLIService(),
    configuration: GitHubPRObservationConfiguration = GitHubPRObservationConfiguration()
  ) {
    self.service = service
    self.configuration = configuration
  }

  public func subscribe(
    to target: GitHubPRObservationTarget,
    refreshOnSubscribe: Bool = true
  ) async -> GitHubPRObservationSubscription {
    let subscriptionID = UUID()
    var continuation: AsyncStream<GitHubPRObservationSnapshot>.Continuation?
    let updates = AsyncStream<GitHubPRObservationSnapshot> { streamContinuation in
      continuation = streamContinuation
    }

    guard let continuation else {
      return GitHubPRObservationSubscription(id: subscriptionID, updates: updates)
    }

    continuation.onTermination = { [subscriptionID] _ in
      Task {
        await self.unsubscribe(subscriptionID: subscriptionID)
      }
    }

    let key = target.key
    var entry = entries[key] ?? Entry(target: target, snapshot: .initial(target: target))
    entry.subscribers[subscriptionID] = continuation
    if !entry.isTerminallyPaused || entry.consecutiveErrorCount == 0 {
      entry.isTerminallyPaused = false
    }
    entries[key] = entry
    subscriptionKeys[subscriptionID] = key

    continuation.yield(entry.snapshot)
    if refreshOnSubscribe {
      scheduleRefreshIfNeeded(for: key, forceImmediate: needsImmediateRefresh(entry, now: .now))
    }

    return GitHubPRObservationSubscription(id: subscriptionID, updates: updates)
  }

  public func unsubscribe(subscriptionID: UUID) async {
    guard let key = subscriptionKeys.removeValue(forKey: subscriptionID),
          var entry = entries[key] else {
      return
    }

    entry.subscribers.removeValue(forKey: subscriptionID)?.finish()
    if entry.subscribers.isEmpty {
      entry.scheduledRefreshTask?.cancel()
      entry.scheduledRefreshTask = nil
    }
    entries[key] = entry
  }

  public func refresh(_ target: GitHubPRObservationTarget) async {
    let key = target.key
    if entries[key] == nil {
      entries[key] = Entry(target: target, snapshot: .initial(target: target))
    }
    scheduleRefreshIfNeeded(for: key, forceImmediate: true)
  }

  public func recordActivity(for target: GitHubPRObservationTarget, at date: Date) async {
    let key = target.key
    guard var entry = entries[key] else { return }

    if let previousActivity = entry.lastActivityAt, previousActivity >= date {
      entries[key] = entry
      return
    }

    entry.lastActivityAt = date
    guard !entry.subscribers.isEmpty else {
      entries[key] = entry
      return
    }
    guard Date.now.timeIntervalSince(date) <= configuration.idleTimeout else {
      entries[key] = entry
      return
    }

    let shouldReactivate = entry.isTerminallyPaused
    if entry.isRefreshing {
      entry.pendingPostRefreshEvaluation = true
      entries[key] = entry
      return
    }

    entry.isTerminallyPaused = false
    entries[key] = entry

    scheduleRefreshIfNeeded(
      for: key,
      forceImmediate: shouldReactivate || needsImmediateRefresh(entry, now: date)
    )
  }

  // MARK: - Scheduling

  private func scheduleRefreshIfNeeded(for key: String, forceImmediate: Bool) {
    guard var entry = entries[key], !entry.subscribers.isEmpty else { return }

    if entry.isRefreshing {
      entry.pendingPostRefreshEvaluation = true
      entries[key] = entry
      return
    }

    if !forceImmediate, entry.scheduledRefreshTask != nil {
      entries[key] = entry
      return
    }

    let now = Date.now
    let interval: TimeInterval
    if forceImmediate {
      interval = 0
    } else if canAutoRefresh(entry, now: now) {
      interval = remainingRefreshInterval(for: entry, now: now)
    } else {
      entries[key] = entry
      return
    }

    entry.scheduledRefreshTask?.cancel()
    entry.scheduledRefreshTask = Task {
      if interval > 0 {
        try? await Task.sleep(for: Self.duration(for: interval))
      }
      guard !Task.isCancelled else { return }
      await self.executeScheduledRefresh(for: key)
    }
    entries[key] = entry
  }

  private func executeScheduledRefresh(for key: String) async {
    guard var entry = entries[key] else { return }

    guard !entry.subscribers.isEmpty else {
      entry.scheduledRefreshTask = nil
      entry.isRefreshing = false
      entry.pendingPostRefreshEvaluation = false
      entries[key] = entry
      return
    }

    if entry.snapshot.lastRefreshedAt != nil, !canAutoRefresh(entry, now: .now) {
      entry.scheduledRefreshTask = nil
      entry.isRefreshing = false
      entry.pendingPostRefreshEvaluation = false
      entries[key] = entry
      return
    }

    entry.isRefreshing = true
    entry.scheduledRefreshTask = nil
    entry.snapshot = GitHubPRObservationSnapshot(
      target: entry.target,
      pullRequest: entry.snapshot.pullRequest,
      checks: entry.snapshot.checks,
      state: .refreshing,
      lastRefreshedAt: entry.snapshot.lastRefreshedAt
    )
    entries[key] = entry
    broadcast(entry.snapshot, for: key)

    let refreshResult = await refreshSnapshot(for: entry.target)

    guard var refreshedEntry = entries[key] else { return }
    refreshedEntry.isRefreshing = false
    refreshedEntry.scheduledRefreshTask = nil
    let hadCoalescedActivity = refreshedEntry.pendingPostRefreshEvaluation
    refreshedEntry.pendingPostRefreshEvaluation = false

    guard !Task.isCancelled, !refreshedEntry.subscribers.isEmpty else {
      entries[key] = refreshedEntry
      return
    }

    switch refreshResult {
    case .success(let snapshot):
      refreshedEntry.snapshot = snapshot
      refreshedEntry.consecutiveErrorCount = 0
      refreshedEntry.isTerminallyPaused = false
      entries[key] = refreshedEntry
      broadcast(snapshot, for: key)

      if canAutoRefresh(refreshedEntry, now: .now) {
        scheduleRefreshIfNeeded(for: key, forceImmediate: false)
      }

    case .failure(let error):
      let message = error.localizedDescription
      if isTerminal(error) {
        refreshedEntry.isTerminallyPaused = true
        refreshedEntry.consecutiveErrorCount = 0
        refreshedEntry.snapshot = GitHubPRObservationSnapshot(
          target: refreshedEntry.target,
          pullRequest: refreshedEntry.snapshot.pullRequest,
          checks: refreshedEntry.snapshot.checks,
          state: .paused(message),
          lastRefreshedAt: refreshedEntry.snapshot.lastRefreshedAt
        )
        entries[key] = refreshedEntry
        broadcast(refreshedEntry.snapshot, for: key)
        return
      }

      refreshedEntry.consecutiveErrorCount += 1
      refreshedEntry.isTerminallyPaused = false
      refreshedEntry.snapshot = GitHubPRObservationSnapshot(
        target: refreshedEntry.target,
        pullRequest: refreshedEntry.snapshot.pullRequest,
        checks: refreshedEntry.snapshot.checks,
        state: .error(message),
        lastRefreshedAt: refreshedEntry.snapshot.lastRefreshedAt
      )
      entries[key] = refreshedEntry
      broadcast(refreshedEntry.snapshot, for: key)

      if canAutoRefresh(refreshedEntry, now: .now) {
        scheduleBackoffRefresh(for: key, errorCount: refreshedEntry.consecutiveErrorCount)
      }
    }

    if hadCoalescedActivity {
      scheduleRefreshIfNeeded(for: key, forceImmediate: false)
    }
  }

  private func scheduleBackoffRefresh(for key: String, errorCount: Int) {
    guard var entry = entries[key], !entry.subscribers.isEmpty else { return }

    let intervals = configuration.errorBackoff
    let index = min(max(0, errorCount - 1), max(0, intervals.count - 1))
    let interval = intervals.isEmpty ? configuration.pendingPollInterval : intervals[index]

    entry.scheduledRefreshTask?.cancel()
    entry.scheduledRefreshTask = Task {
      if interval > 0 {
        try? await Task.sleep(for: Self.duration(for: interval))
      }
      guard !Task.isCancelled else { return }
      await self.executeScheduledRefresh(for: key)
    }
    entries[key] = entry
  }

  private func broadcast(_ snapshot: GitHubPRObservationSnapshot, for key: String) {
    guard let entry = entries[key] else { return }
    for continuation in entry.subscribers.values {
      continuation.yield(snapshot)
    }
  }

  // MARK: - Fetching

  private func refreshSnapshot(
    for target: GitHubPRObservationTarget
  ) async -> Result<GitHubPRObservationSnapshot, Error> {
    do {
      switch target {
      case .currentBranch(let projectPath, _):
        guard let pullRequest = try await service.getCurrentBranchPR(at: projectPath) else {
          return .success(GitHubPRObservationSnapshot(
            target: target,
            pullRequest: nil,
            checks: [],
            state: .ready,
            lastRefreshedAt: .now
          ))
        }
        let checks = try await service.getChecks(prNumber: pullRequest.number, at: projectPath)
        return .success(GitHubPRObservationSnapshot(
          target: target,
          pullRequest: pullRequest,
          checks: checks,
          state: .ready,
          lastRefreshedAt: .now
        ))

      case .pullRequest(let projectPath, let number):
        async let pullRequest = service.getPullRequest(number: number, at: projectPath)
        async let checks = service.getChecks(prNumber: number, at: projectPath)
        let (resolvedPullRequest, resolvedChecks) = try await (pullRequest, checks)
        let snapshot = GitHubPRObservationSnapshot(
          target: target,
          pullRequest: resolvedPullRequest,
          checks: resolvedChecks,
          state: .ready,
          lastRefreshedAt: .now
        )
        return .success(snapshot)
      }
    } catch {
      return .failure(error)
    }
  }

  // MARK: - Helpers

  private func canAutoRefresh(_ entry: Entry, now: Date) -> Bool {
    guard !entry.isTerminallyPaused, !entry.subscribers.isEmpty else { return false }
    guard let lastActivityAt = entry.lastActivityAt else { return entry.snapshot.lastRefreshedAt == nil }
    return now.timeIntervalSince(lastActivityAt) <= configuration.idleTimeout
  }

  private func needsImmediateRefresh(_ entry: Entry, now: Date) -> Bool {
    guard let lastRefreshedAt = entry.snapshot.lastRefreshedAt else { return true }
    return now.timeIntervalSince(lastRefreshedAt) >= pollingInterval(for: entry.snapshot)
  }

  private func remainingRefreshInterval(for entry: Entry, now: Date) -> TimeInterval {
    guard let lastRefreshedAt = entry.snapshot.lastRefreshedAt else { return 0 }
    return max(0, pollingInterval(for: entry.snapshot) - now.timeIntervalSince(lastRefreshedAt))
  }

  private func pollingInterval(for snapshot: GitHubPRObservationSnapshot) -> TimeInterval {
    if snapshot.pullRequest == nil || snapshot.ciSummary.pending > 0 {
      return configuration.pendingPollInterval
    }
    return configuration.settledPollInterval
  }

  private func isTerminal(_ error: Error) -> Bool {
    guard let gitHubError = error as? GitHubCLIError else { return false }

    switch gitHubError {
    case .cliNotInstalled, .notAuthenticated, .notAGitRepository, .noRemoteRepository:
      return true
    case .commandFailed, .parseError, .timeout:
      return false
    }
  }

  private static func duration(for interval: TimeInterval) -> Duration {
    .milliseconds(max(0, Int(interval * 1_000)))
  }
}
