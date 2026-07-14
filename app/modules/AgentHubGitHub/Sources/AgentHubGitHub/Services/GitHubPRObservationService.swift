//
//  GitHubPRObservationService.swift
//  AgentHub
//
//  Shared, performance-bounded PR/check observation for GitHub surfaces.
//

import Foundation

public enum GitHubPRObservationTarget: Hashable, Sendable {
  case session(
    projectPath: String,
    branchName: String?,
    linkedPullRequests: [GitHubPullRequestURLReference]
  )
  case pullRequest(projectPath: String, number: Int)

  public var projectPath: String {
    switch self {
    case .session(let projectPath, _, _), .pullRequest(let projectPath, _):
      projectPath
    }
  }

  public var pullRequestNumber: Int? {
    switch self {
    case .session:
      nil
    case .pullRequest(_, let number):
      number
    }
  }

  var key: String {
    switch self {
    case .session(let projectPath, let branchName, let linkedPullRequests):
      let links = linkedPullRequests
        .map { "\($0.owner.lowercased())/\($0.repository.lowercased())#\($0.number)" }
        .joined(separator: ",")
      return "session|\(projectPath)|\(branchName ?? "")|\(links)"
    case .pullRequest(let projectPath, let number):
      return "pr|\(projectPath)|\(number)"
    }
  }

  public static func currentBranch(
    projectPath: String,
    branchName: String?
  ) -> GitHubPRObservationTarget {
    .session(
      projectPath: projectPath,
      branchName: branchName,
      linkedPullRequests: []
    )
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

  public var isUnavailable: Bool {
    switch self {
    case .error, .paused:
      true
    case .idle, .refreshing, .ready:
      false
    }
  }
}

public enum GitHubPRBlocker: Int, CaseIterable, Hashable, Sendable {
  case ciFailure
  case changesRequested
  case mergeConflict

  public var displayName: String {
    switch self {
    case .ciFailure: "CI failing"
    case .changesRequested: "Changes requested"
    case .mergeConflict: "Merge conflict"
    }
  }

  public static func blockers(
    for pullRequest: GitHubPullRequest?,
    ciSummary: GitHubCISummary
  ) -> Set<GitHubPRBlocker> {
    guard let pullRequest, pullRequest.stateKind == .open else { return [] }
    var blockers: Set<GitHubPRBlocker> = []
    if ciSummary.failed > 0 {
      blockers.insert(.ciFailure)
    }
    if pullRequest.reviewDecisionKind == .changesRequested {
      blockers.insert(.changesRequested)
    }
    if pullRequest.mergeabilityKind == .conflicting {
      blockers.insert(.mergeConflict)
    }
    return blockers
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
  public let blockers: Set<GitHubPRBlocker>
  public let state: GitHubPRObservationState
  /// The last time PR metadata and CI checks were both fetched successfully.
  public let lastRefreshedAt: Date?

  public init(
    target: GitHubPRObservationTarget,
    pullRequest: GitHubPullRequest?,
    checks: [GitHubCheckRun],
    state: GitHubPRObservationState,
    lastRefreshedAt: Date?
  ) {
    let ciSummary = GitHubCISummary(checks: checks)
    self.target = target
    self.pullRequest = pullRequest
    self.checks = checks
    self.ciSummary = ciSummary
    self.blockers = GitHubPRBlocker.blockers(for: pullRequest, ciSummary: ciSummary)
    self.state = state
    self.lastRefreshedAt = lastRefreshedAt
  }

  public var isStale: Bool {
    state.isUnavailable && lastRefreshedAt != nil
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
  /// Performs or joins a refresh and returns only after that refresh completes.
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
  public var idlePendingPollInterval: TimeInterval
  public var settledPollInterval: TimeInterval
  public var idleTimeout: TimeInterval
  public var checksDiscoveryWindow: TimeInterval
  public var pendingObservationLimit: TimeInterval
  public var inactiveEntryRetention: TimeInterval
  public var maximumConcurrentRefreshes: Int
  public var errorBackoff: [TimeInterval]

  public init(
    pendingPollInterval: TimeInterval = 30,
    idlePendingPollInterval: TimeInterval = 120,
    settledPollInterval: TimeInterval = 120,
    idleTimeout: TimeInterval = 5 * 60,
    checksDiscoveryWindow: TimeInterval = 10 * 60,
    pendingObservationLimit: TimeInterval = 60 * 60,
    inactiveEntryRetention: TimeInterval = 15 * 60,
    maximumConcurrentRefreshes: Int = 2,
    errorBackoff: [TimeInterval] = [60, 120, 300]
  ) {
    self.pendingPollInterval = pendingPollInterval
    self.idlePendingPollInterval = idlePendingPollInterval
    self.settledPollInterval = settledPollInterval
    self.idleTimeout = idleTimeout
    self.checksDiscoveryWindow = checksDiscoveryWindow
    self.pendingObservationLimit = pendingObservationLimit
    self.inactiveEntryRetention = inactiveEntryRetention
    self.maximumConcurrentRefreshes = max(1, maximumConcurrentRefreshes)
    self.errorBackoff = errorBackoff
  }
}

private enum GitHubObservationRefreshPriority: Sendable {
  case automatic
  case manual
}

private actor GitHubObservationRefreshLimiter {
  private let limit: Int
  private var activeCount = 0
  private var manualWaiters: [CheckedContinuation<Void, Never>] = []
  private var automaticWaiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire(priority: GitHubObservationRefreshPriority) async {
    if activeCount < limit {
      activeCount += 1
      return
    }

    await withCheckedContinuation { continuation in
      switch priority {
      case .automatic:
        automaticWaiters.append(continuation)
      case .manual:
        manualWaiters.append(continuation)
      }
    }
  }

  func release() {
    if !manualWaiters.isEmpty {
      manualWaiters.removeFirst().resume()
    } else if !automaticWaiters.isEmpty {
      automaticWaiters.removeFirst().resume()
    } else {
      activeCount = max(0, activeCount - 1)
    }
  }
}

public actor GitHubPRObservationService: GitHubPRObservationServiceProtocol {
  private struct Entry {
    let target: GitHubPRObservationTarget
    var snapshot: GitHubPRObservationSnapshot
    var lastActivityAt: Date?
    var lastUsedAt = Date.now
    var checksDiscoveryDeadline: Date?
    var pendingObservationDeadline: Date?
    var observedHeadOID: String?
    var consecutiveErrorCount = 0
    var isTerminallyPaused = false
    var isRefreshing = false
    var pendingPostRefreshEvaluation = false
    var scheduledRefreshTask: Task<Void, Never>?
    var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    var subscribers: [UUID: AsyncStream<GitHubPRObservationSnapshot>.Continuation] = [:]
  }

  private enum RefreshResult {
    case success(GitHubPRObservationSnapshot)
    case degraded(GitHubPRObservationSnapshot, Error)
    case failure(Error)
  }

  private let service: any GitHubCLIServiceProtocol
  private let repositoryIdentityResolver: any GitHubRepositoryIdentityResolverProtocol
  private let configuration: GitHubPRObservationConfiguration
  private let refreshLimiter: GitHubObservationRefreshLimiter
  private var entries: [String: Entry] = [:]
  private var subscriptionKeys: [UUID: String] = [:]

  public init(
    service: any GitHubCLIServiceProtocol = GitHubCLIService(),
    repositoryIdentityResolver: any GitHubRepositoryIdentityResolverProtocol = GitHubRepositoryIdentityResolver(),
    configuration: GitHubPRObservationConfiguration = GitHubPRObservationConfiguration()
  ) {
    self.service = service
    self.repositoryIdentityResolver = repositoryIdentityResolver
    self.configuration = configuration
    self.refreshLimiter = GitHubObservationRefreshLimiter(
      limit: configuration.maximumConcurrentRefreshes
    )
  }

  public func subscribe(
    to target: GitHubPRObservationTarget,
    refreshOnSubscribe: Bool = true
  ) async -> GitHubPRObservationSubscription {
    pruneInactiveEntries(now: .now)

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
    entry.lastUsedAt = .now
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
    entry.lastUsedAt = .now
    if entry.subscribers.isEmpty {
      entry.scheduledRefreshTask?.cancel()
      entry.scheduledRefreshTask = nil
    }
    entries[key] = entry
  }

  public func refresh(_ target: GitHubPRObservationTarget) async {
    pruneInactiveEntries(now: .now)

    let key = target.key
    var entry = entries[key] ?? Entry(target: target, snapshot: .initial(target: target))
    entry.lastUsedAt = .now
    entry.isTerminallyPaused = false
    entry.scheduledRefreshTask?.cancel()
    entry.scheduledRefreshTask = nil
    entries[key] = entry

    if entry.isRefreshing {
      await waitForRefresh(for: key)
      return
    }

    await executeRefresh(
      for: key,
      allowsWithoutSubscribers: true,
      priority: .manual
    )
  }

  public func recordActivity(for target: GitHubPRObservationTarget, at date: Date) async {
    pruneInactiveEntries(now: .now)

    let key = target.key
    guard var entry = entries[key] else { return }

    if let previousActivity = entry.lastActivityAt, previousActivity >= date {
      return
    }

    entry.lastActivityAt = date
    entry.lastUsedAt = .now
    if entry.snapshot.pullRequest?.stateKind.isTerminal == true {
      entry.pendingObservationDeadline = nil
      entry.checksDiscoveryDeadline = nil
      entries[key] = entry
      return
    }

    if entry.snapshot.ciSummary.pending == 0,
       entry.snapshot.pullRequest == nil || entry.snapshot.checks.isEmpty {
      entry.checksDiscoveryDeadline = maxDate(
        entry.checksDiscoveryDeadline,
        date.addingTimeInterval(configuration.checksDiscoveryWindow)
      )
    }

    guard !entry.subscribers.isEmpty else {
      entries[key] = entry
      return
    }
    guard Date.now.timeIntervalSince(date) <= configuration.idleTimeout else {
      entries[key] = entry
      return
    }

    let shouldReactivate = entry.isTerminallyPaused
    entry.isTerminallyPaused = false
    if entry.isRefreshing {
      entry.pendingPostRefreshEvaluation = true
      entries[key] = entry
      return
    }

    entries[key] = entry
    scheduleRefreshIfNeeded(
      for: key,
      forceImmediate: shouldReactivate || needsImmediateRefresh(entry, now: date)
    )
  }

  // MARK: - Scheduling

  private func scheduleRefreshIfNeeded(for key: String, forceImmediate: Bool) {
    guard var entry = entries[key], !entry.subscribers.isEmpty else { return }
    guard entry.snapshot.pullRequest?.stateKind.isTerminal != true else { return }

    if entry.isRefreshing {
      entry.pendingPostRefreshEvaluation = true
      entries[key] = entry
      return
    }

    if !forceImmediate, entry.scheduledRefreshTask != nil {
      return
    }

    let now = Date.now
    let interval: TimeInterval
    if forceImmediate {
      interval = 0
    } else if canAutoRefresh(entry, now: now) {
      interval = remainingRefreshInterval(for: entry, now: now)
    } else {
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
    entry.scheduledRefreshTask = nil
    entries[key] = entry

    guard canAutoRefresh(entry, now: .now) else { return }
    await executeRefresh(
      for: key,
      allowsWithoutSubscribers: false,
      priority: .automatic
    )
  }

  private func executeRefresh(
    for key: String,
    allowsWithoutSubscribers: Bool,
    priority: GitHubObservationRefreshPriority
  ) async {
    guard var entry = entries[key] else { return }
    guard allowsWithoutSubscribers || !entry.subscribers.isEmpty else { return }

    if entry.isRefreshing {
      entry.pendingPostRefreshEvaluation = true
      entries[key] = entry
      return
    }

    entry.isRefreshing = true
    entry.lastUsedAt = .now
    entry.snapshot = GitHubPRObservationSnapshot(
      target: entry.target,
      pullRequest: entry.snapshot.pullRequest,
      checks: entry.snapshot.checks,
      state: .refreshing,
      lastRefreshedAt: entry.snapshot.lastRefreshedAt
    )
    let target = entry.target
    let previousSnapshot = entry.snapshot
    entries[key] = entry
    broadcast(entry.snapshot, for: key)

    await refreshLimiter.acquire(priority: priority)

    guard let permittedEntry = entries[key],
          allowsWithoutSubscribers || !permittedEntry.subscribers.isEmpty else {
      await refreshLimiter.release()
      finishRefreshWithoutResult(for: key)
      return
    }

    let refreshResult = await refreshSnapshot(
      for: target,
      previousSnapshot: previousSnapshot
    )
    await refreshLimiter.release()
    apply(refreshResult, for: key)
  }

  private func apply(_ result: RefreshResult, for key: String) {
    guard var entry = entries[key] else { return }
    entry.isRefreshing = false
    entry.scheduledRefreshTask = nil
    entry.lastUsedAt = .now
    let hadCoalescedActivity = entry.pendingPostRefreshEvaluation
    entry.pendingPostRefreshEvaluation = false

    switch result {
    case .success(let snapshot):
      entry.snapshot = snapshot
      entry.consecutiveErrorCount = 0
      entry.isTerminallyPaused = false
      updateObservationWindows(for: &entry, snapshot: snapshot, now: .now)

    case .degraded(let snapshot, let error):
      entry.snapshot = snapshot
      apply(error: error, to: &entry)

    case .failure(let error):
      let state: GitHubPRObservationState = isTerminal(error)
        ? .paused(error.localizedDescription)
        : .error(error.localizedDescription)
      entry.snapshot = GitHubPRObservationSnapshot(
        target: entry.target,
        pullRequest: entry.snapshot.pullRequest,
        checks: entry.snapshot.checks,
        state: state,
        lastRefreshedAt: entry.snapshot.lastRefreshedAt
      )
      apply(error: error, to: &entry)
    }

    let snapshot = entry.snapshot
    let waiters = entry.refreshWaiters
    entry.refreshWaiters.removeAll()
    entries[key] = entry
    broadcast(snapshot, for: key)
    waiters.forEach { $0.resume() }

    guard !entry.subscribers.isEmpty else { return }

    if entry.isTerminallyPaused {
      return
    } else if entry.consecutiveErrorCount > 0 {
      if canAutoRefresh(entry, now: .now) {
        scheduleBackoffRefresh(for: key, errorCount: entry.consecutiveErrorCount)
      }
    } else if canAutoRefresh(entry, now: .now) {
      scheduleRefreshIfNeeded(for: key, forceImmediate: false)
    }

    if hadCoalescedActivity {
      scheduleRefreshIfNeeded(for: key, forceImmediate: false)
    }
  }

  private func apply(error: Error, to entry: inout Entry) {
    if isTerminal(error) {
      entry.isTerminallyPaused = true
      entry.consecutiveErrorCount = 0
    } else {
      entry.isTerminallyPaused = false
      entry.consecutiveErrorCount += 1
    }
  }

  private func finishRefreshWithoutResult(for key: String) {
    guard var entry = entries[key] else { return }
    entry.isRefreshing = false
    let waiters = entry.refreshWaiters
    entry.refreshWaiters.removeAll()
    entries[key] = entry
    waiters.forEach { $0.resume() }
  }

  private func waitForRefresh(for key: String) async {
    await withCheckedContinuation { continuation in
      guard var entry = entries[key], entry.isRefreshing else {
        continuation.resume()
        return
      }
      entry.refreshWaiters.append(continuation)
      entries[key] = entry
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
    for target: GitHubPRObservationTarget,
    previousSnapshot: GitHubPRObservationSnapshot
  ) async -> RefreshResult {
    do {
      let pullRequest: GitHubPullRequest?
      switch target {
      case .session(let projectPath, let branchName, let linkedPullRequests):
        let identity = await repositoryIdentityResolver.resolveIdentity(at: projectPath)
        if let identity,
           let linkedPullRequest = GitHubPullRequestURLReference.latest(
             matching: identity,
             in: linkedPullRequests
           ) {
          pullRequest = try await service.getPullRequest(
            number: linkedPullRequest.number,
            at: projectPath
          )
        } else {
          pullRequest = try await service.getCurrentBranchPR(
            branchName: branchName,
            at: projectPath
          )
        }

      case .pullRequest(let projectPath, let number):
        pullRequest = try await service.getPullRequest(number: number, at: projectPath)
      }

      guard let pullRequest else {
        return .success(GitHubPRObservationSnapshot(
          target: target,
          pullRequest: nil,
          checks: [],
          state: .ready,
          lastRefreshedAt: .now
        ))
      }

      if let checks = pullRequest.statusCheckRollup {
        return .success(GitHubPRObservationSnapshot(
          target: target,
          pullRequest: pullRequest,
          checks: checks,
          state: .ready,
          lastRefreshedAt: .now
        ))
      }

      do {
        let checks = try await service.getChecks(
          prNumber: pullRequest.number,
          at: target.projectPath
        )
        return .success(GitHubPRObservationSnapshot(
          target: target,
          pullRequest: pullRequest,
          checks: checks,
          state: .ready,
          lastRefreshedAt: .now
        ))
      } catch {
        let isSameHead = previousSnapshot.pullRequest?.headRefOid == pullRequest.headRefOid
          && pullRequest.headRefOid != nil
        return .degraded(GitHubPRObservationSnapshot(
          target: target,
          pullRequest: pullRequest,
          checks: isSameHead ? previousSnapshot.checks : [],
          state: isTerminal(error)
            ? .paused(error.localizedDescription)
            : .error(error.localizedDescription),
          lastRefreshedAt: isSameHead ? previousSnapshot.lastRefreshedAt : nil
        ), error)
      }
    } catch {
      return .failure(error)
    }
  }

  // MARK: - Helpers

  private func updateObservationWindows(
    for entry: inout Entry,
    snapshot: GitHubPRObservationSnapshot,
    now: Date
  ) {
    if snapshot.pullRequest?.stateKind.isTerminal == true {
      entry.observedHeadOID = snapshot.pullRequest?.headRefOid
      entry.pendingObservationDeadline = nil
      entry.checksDiscoveryDeadline = nil
      return
    }

    let headOID = snapshot.pullRequest?.headRefOid
    let isNewHead = headOID != entry.observedHeadOID
    entry.observedHeadOID = headOID

    if snapshot.ciSummary.pending > 0 {
      if isNewHead || entry.pendingObservationDeadline == nil {
        entry.pendingObservationDeadline = now.addingTimeInterval(
          configuration.pendingObservationLimit
        )
      }
      entry.checksDiscoveryDeadline = nil
    } else if snapshot.pullRequest == nil || snapshot.checks.isEmpty {
      entry.pendingObservationDeadline = nil
      if isNewHead || entry.checksDiscoveryDeadline == nil {
        entry.checksDiscoveryDeadline = now.addingTimeInterval(
          configuration.checksDiscoveryWindow
        )
      }
    } else {
      entry.pendingObservationDeadline = nil
      entry.checksDiscoveryDeadline = nil
    }
  }

  private func canAutoRefresh(_ entry: Entry, now: Date) -> Bool {
    guard !entry.isTerminallyPaused, !entry.subscribers.isEmpty else { return false }
    guard entry.snapshot.pullRequest?.stateKind.isTerminal != true else { return false }

    if entry.snapshot.ciSummary.pending > 0 {
      return entry.pendingObservationDeadline.map { now <= $0 } ?? false
    }

    if (entry.snapshot.pullRequest == nil || entry.snapshot.checks.isEmpty),
       let deadline = entry.checksDiscoveryDeadline {
      return now <= deadline
    }

    guard let lastActivityAt = entry.lastActivityAt else {
      return entry.snapshot.lastRefreshedAt == nil
    }
    return now.timeIntervalSince(lastActivityAt) <= configuration.idleTimeout
  }

  private func needsImmediateRefresh(_ entry: Entry, now: Date) -> Bool {
    guard entry.snapshot.pullRequest?.stateKind.isTerminal != true else { return false }
    guard let lastRefreshedAt = entry.snapshot.lastRefreshedAt else { return true }
    return now.timeIntervalSince(lastRefreshedAt) >= pollingInterval(for: entry, now: now)
  }

  private func remainingRefreshInterval(for entry: Entry, now: Date) -> TimeInterval {
    guard let lastRefreshedAt = entry.snapshot.lastRefreshedAt else { return 0 }
    return max(
      0,
      pollingInterval(for: entry, now: now) - now.timeIntervalSince(lastRefreshedAt)
    )
  }

  private func pollingInterval(for entry: Entry, now: Date) -> TimeInterval {
    let isRecentlyActive = entry.lastActivityAt.map {
      now.timeIntervalSince($0) <= configuration.idleTimeout
    } ?? false

    if entry.snapshot.ciSummary.pending > 0 || entry.snapshot.checks.isEmpty {
      return isRecentlyActive
        ? configuration.pendingPollInterval
        : configuration.idlePendingPollInterval
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

  private func pruneInactiveEntries(now: Date) {
    let staleKeys = entries.compactMap { key, entry -> String? in
      guard entry.subscribers.isEmpty,
            !entry.isRefreshing,
            now.timeIntervalSince(entry.lastUsedAt) >= configuration.inactiveEntryRetention else {
        return nil
      }
      return key
    }
    for key in staleKeys {
      entries[key]?.scheduledRefreshTask?.cancel()
      entries.removeValue(forKey: key)
    }
  }

  private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
    guard let lhs else { return rhs }
    return max(lhs, rhs)
  }

  private static func duration(for interval: TimeInterval) -> Duration {
    .milliseconds(max(0, Int(interval * 1_000)))
  }
}
