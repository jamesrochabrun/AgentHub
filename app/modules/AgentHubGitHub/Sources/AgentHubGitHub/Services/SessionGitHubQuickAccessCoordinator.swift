//
//  SessionGitHubQuickAccessCoordinator.swift
//  AgentHub
//
//  Shared current-branch PR refresh for session cards
//

import Foundation

public struct SessionGitHubQuickAccessSubscription: Sendable {
  public let id: UUID
  public let updates: AsyncStream<GitHubPullRequest?>

  public init(id: UUID, updates: AsyncStream<GitHubPullRequest?>) {
    self.id = id
    self.updates = updates
  }
}

public protocol SessionGitHubQuickAccessCoordinatorProtocol: AnyObject, Sendable {
  func subscribe(projectPath: String, branchName: String?) async -> SessionGitHubQuickAccessSubscription
  func unsubscribe(subscriptionID: UUID) async
  func recordActivity(projectPath: String, branchName: String?, at: Date) async
}

public struct SessionGitHubQuickAccessCoordinatorConfiguration: Sendable {
  public var missingPRPollInterval: TimeInterval = 30
  public var existingPRPollInterval: TimeInterval = 120
  public var idleTimeout: TimeInterval = 5 * 60
  public var errorBackoff: [TimeInterval] = [60, 120, 300]

  public init(
    missingPRPollInterval: TimeInterval = 30,
    existingPRPollInterval: TimeInterval = 120,
    idleTimeout: TimeInterval = 5 * 60,
    errorBackoff: [TimeInterval] = [60, 120, 300]
  ) {
    self.missingPRPollInterval = missingPRPollInterval
    self.existingPRPollInterval = existingPRPollInterval
    self.idleTimeout = idleTimeout
    self.errorBackoff = errorBackoff
  }
}

public actor SessionGitHubQuickAccessCoordinator: SessionGitHubQuickAccessCoordinatorProtocol {

  private struct Entry {
    let projectPath: String
    let branchName: String?
    var currentBranchPR: GitHubPullRequest?
    var lastRefreshAt: Date?
    var lastActivityAt: Date?
    var consecutiveErrorCount = 0
    var isTerminallyPaused = false
    var isRefreshing = false
    var pendingPostRefreshEvaluation = false
    var scheduledRefreshTask: Task<Void, Never>?
    var subscribers: [UUID: AsyncStream<GitHubPullRequest?>.Continuation] = [:]
  }

  private let service: any GitHubCLIServiceProtocol
  private let configuration: SessionGitHubQuickAccessCoordinatorConfiguration
  private var entries: [String: Entry] = [:]
  private var subscriptionKeys: [UUID: String] = [:]

  public init(
    service: any GitHubCLIServiceProtocol = GitHubCLIService(),
    configuration: SessionGitHubQuickAccessCoordinatorConfiguration = SessionGitHubQuickAccessCoordinatorConfiguration()
  ) {
    self.service = service
    self.configuration = configuration
  }

  public func subscribe(projectPath: String, branchName: String?) async -> SessionGitHubQuickAccessSubscription {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: projectPath,
      branchName: branchName
    )
    let subscriptionID = UUID()

    var continuation: AsyncStream<GitHubPullRequest?>.Continuation?
    let updates = AsyncStream<GitHubPullRequest?> { streamContinuation in
      continuation = streamContinuation
    }

    guard let continuation else {
      return SessionGitHubQuickAccessSubscription(id: subscriptionID, updates: updates)
    }

    continuation.onTermination = { [subscriptionID] _ in
      Task {
        await self.unsubscribe(subscriptionID: subscriptionID)
      }
    }

    var entry = entries[repositoryKey] ?? Entry(projectPath: projectPath, branchName: branchName)
    entry.subscribers[subscriptionID] = continuation
    // Only un-pause for transient errors (timeout, command failures). Auth/install/repo
    // errors won't resolve without user action, so preserve the terminal pause to avoid
    // hammering gh on every SwiftUI view rebuild.
    if !entry.isTerminallyPaused || entry.consecutiveErrorCount == 0 {
      entry.isTerminallyPaused = false
    }
    entries[repositoryKey] = entry
    subscriptionKeys[subscriptionID] = repositoryKey

    GitHubLogger.github.debug(
      "[QuickAccess] subscribe key=\(repositoryKey, privacy: .public) subscribers=\(entry.subscribers.count)"
    )

    continuation.yield(entry.currentBranchPR)
    scheduleRefreshIfNeeded(for: repositoryKey, forceImmediate: needsImmediateRefresh(entry, now: .now))

    return SessionGitHubQuickAccessSubscription(id: subscriptionID, updates: updates)
  }

  public func unsubscribe(subscriptionID: UUID) async {
    guard let repositoryKey = subscriptionKeys.removeValue(forKey: subscriptionID),
          var entry = entries[repositoryKey] else {
      return
    }

    let continuation = entry.subscribers.removeValue(forKey: subscriptionID)
    continuation?.finish()

    if entry.subscribers.isEmpty {
      entry.scheduledRefreshTask?.cancel()
      entry.scheduledRefreshTask = nil
    }

    entries[repositoryKey] = entry
    GitHubLogger.github.debug(
      "[QuickAccess] unsubscribe key=\(repositoryKey, privacy: .public) subscribers=\(entry.subscribers.count)"
    )
  }

  public func recordActivity(projectPath: String, branchName: String?, at: Date) async {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: projectPath,
      branchName: branchName
    )
    guard var entry = entries[repositoryKey] else { return }

    if let previousActivity = entry.lastActivityAt, previousActivity >= at {
      entries[repositoryKey] = entry
      return
    }

    entry.lastActivityAt = at
    guard !entry.subscribers.isEmpty else {
      entries[repositoryKey] = entry
      return
    }

    let shouldReactivate = entry.isTerminallyPaused
    if entry.isRefreshing {
      entry.pendingPostRefreshEvaluation = true
      entries[repositoryKey] = entry
      GitHubLogger.github.debug(
        "[QuickAccess] coalesced activity during refresh key=\(repositoryKey, privacy: .public)"
      )
      return
    }

    entry.isTerminallyPaused = false
    entries[repositoryKey] = entry

    let shouldForceImmediate = shouldReactivate || needsImmediateRefresh(entry, now: at)
    scheduleRefreshIfNeeded(for: repositoryKey, forceImmediate: shouldForceImmediate)
  }

  // MARK: - Scheduling

  private func scheduleRefreshIfNeeded(for repositoryKey: String, forceImmediate: Bool) {
    guard var entry = entries[repositoryKey], !entry.subscribers.isEmpty else { return }

    if entry.isRefreshing {
      entry.pendingPostRefreshEvaluation = true
      entries[repositoryKey] = entry
      GitHubLogger.github.debug(
        "[QuickAccess] deferred schedule while refresh in flight key=\(repositoryKey, privacy: .public)"
      )
      return
    }

    if !forceImmediate, entry.scheduledRefreshTask != nil {
      entries[repositoryKey] = entry
      return
    }

    let now = Date.now
    let interval: TimeInterval
    if forceImmediate {
      interval = 0
    } else if canAutoRefresh(entry, now: now) {
      interval = remainingRefreshInterval(for: entry, now: now)
    } else {
      entries[repositoryKey] = entry
      return
    }

    entry.scheduledRefreshTask?.cancel()
    entry.scheduledRefreshTask = Task {
      let delay = Self.duration(for: interval)
      if interval > 0 {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled else { return }
      await self.executeScheduledRefresh(for: repositoryKey)
    }
    entries[repositoryKey] = entry

    GitHubLogger.github.debug(
      "[QuickAccess] scheduled refresh key=\(repositoryKey, privacy: .public) immediate=\(forceImmediate) interval=\(interval, privacy: .public)s"
    )
  }

  private func executeScheduledRefresh(for repositoryKey: String) async {
    guard var entry = entries[repositoryKey] else { return }

    guard !entry.subscribers.isEmpty else {
      entry.scheduledRefreshTask = nil
      entry.isRefreshing = false
      entry.pendingPostRefreshEvaluation = false
      entries[repositoryKey] = entry
      return
    }

    if entry.lastRefreshAt != nil, !canAutoRefresh(entry, now: .now) {
      entry.scheduledRefreshTask = nil
      entry.isRefreshing = false
      entry.pendingPostRefreshEvaluation = false
      entries[repositoryKey] = entry
      GitHubLogger.github.debug(
        "[QuickAccess] refresh skipped key=\(repositoryKey, privacy: .public) reason=inactive"
      )
      return
    }

    let clock = ContinuousClock()
    let refreshStart = clock.now
    entry.isRefreshing = true
    entries[repositoryKey] = entry
    GitHubLogger.github.debug("[QuickAccess] refresh start key=\(repositoryKey, privacy: .public)")

    let refreshResult = await refreshCurrentBranchPR(at: entry.projectPath)

    guard var refreshedEntry = entries[repositoryKey] else { return }
    refreshedEntry.isRefreshing = false
    refreshedEntry.scheduledRefreshTask = nil
    let hadCoalescedActivity = refreshedEntry.pendingPostRefreshEvaluation
    refreshedEntry.pendingPostRefreshEvaluation = false

    if Task.isCancelled {
      entries[repositoryKey] = refreshedEntry
      GitHubLogger.github.debug("[QuickAccess] refresh cancelled key=\(repositoryKey, privacy: .public)")
      return
    }

    guard !refreshedEntry.subscribers.isEmpty else {
      entries[repositoryKey] = refreshedEntry
      return
    }

    switch refreshResult {
    case .success(let currentBranchPR):
      refreshedEntry.currentBranchPR = currentBranchPR
      refreshedEntry.lastRefreshAt = .now
      refreshedEntry.consecutiveErrorCount = 0
      refreshedEntry.isTerminallyPaused = false
      entries[repositoryKey] = refreshedEntry
      broadcast(currentBranchPR, for: repositoryKey)
      GitHubLogger.github.info(
        "[QuickAccess] refresh success key=\(repositoryKey, privacy: .public) elapsed=\(clock.now - refreshStart)"
      )

      if canAutoRefresh(refreshedEntry, now: .now) {
        scheduleRefreshIfNeeded(for: repositoryKey, forceImmediate: false)
      }

    case .failure(let error):
      if isTerminal(error) {
        refreshedEntry.isTerminallyPaused = true
        refreshedEntry.consecutiveErrorCount = 0
        entries[repositoryKey] = refreshedEntry
        GitHubLogger.github.info(
          "[QuickAccess] terminal pause key=\(repositoryKey, privacy: .public) elapsed=\(clock.now - refreshStart)"
        )
        return
      }

      refreshedEntry.consecutiveErrorCount += 1
      refreshedEntry.isTerminallyPaused = false
      entries[repositoryKey] = refreshedEntry
      GitHubLogger.github.info(
        "[QuickAccess] recoverable failure key=\(repositoryKey, privacy: .public) elapsed=\(clock.now - refreshStart) backoffCount=\(refreshedEntry.consecutiveErrorCount)"
      )

      if canAutoRefresh(refreshedEntry, now: .now) {
        scheduleBackoffRefresh(for: repositoryKey, errorCount: refreshedEntry.consecutiveErrorCount)
      }
    }

    if hadCoalescedActivity {
      GitHubLogger.github.debug(
        "[QuickAccess] coalesced activity applied after refresh key=\(repositoryKey, privacy: .public)"
      )
    }
  }

  private func scheduleBackoffRefresh(for repositoryKey: String, errorCount: Int) {
    guard var entry = entries[repositoryKey], !entry.subscribers.isEmpty else { return }

    let intervals = configuration.errorBackoff
    let index = min(max(0, errorCount - 1), max(0, intervals.count - 1))
    let interval = intervals[index]

    if entry.isRefreshing {
      entry.pendingPostRefreshEvaluation = true
      entries[repositoryKey] = entry
      return
    }

    entry.scheduledRefreshTask?.cancel()
    entry.scheduledRefreshTask = Task {
      let delay = Self.duration(for: interval)
      if interval > 0 {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled else { return }
      await self.executeScheduledRefresh(for: repositoryKey)
    }
    entries[repositoryKey] = entry
    GitHubLogger.github.debug(
      "[QuickAccess] scheduled backoff key=\(repositoryKey, privacy: .public) interval=\(interval, privacy: .public)s"
    )
  }

  private func broadcast(_ currentBranchPR: GitHubPullRequest?, for repositoryKey: String) {
    guard let entry = entries[repositoryKey] else { return }
    for continuation in entry.subscribers.values {
      continuation.yield(currentBranchPR)
    }
  }

  // MARK: - Refresh Helpers

  private func refreshCurrentBranchPR(at projectPath: String) async -> Result<GitHubPullRequest?, Error> {
    do {
      return .success(try await service.getCurrentBranchPR(at: projectPath))
    } catch {
      return .failure(error)
    }
  }

  private func canAutoRefresh(_ entry: Entry, now: Date) -> Bool {
    guard !entry.isTerminallyPaused, !entry.subscribers.isEmpty else { return false }
    guard let lastActivityAt = entry.lastActivityAt else { return false }
    return now.timeIntervalSince(lastActivityAt) <= configuration.idleTimeout
  }

  private func needsImmediateRefresh(_ entry: Entry, now: Date) -> Bool {
    guard let lastRefreshAt = entry.lastRefreshAt else { return true }
    return now.timeIntervalSince(lastRefreshAt) >= pollingInterval(for: entry)
  }

  private func remainingRefreshInterval(for entry: Entry, now: Date) -> TimeInterval {
    guard let lastRefreshAt = entry.lastRefreshAt else { return 0 }
    return max(0, pollingInterval(for: entry) - now.timeIntervalSince(lastRefreshAt))
  }

  private func pollingInterval(for entry: Entry) -> TimeInterval {
    if entry.currentBranchPR == nil {
      configuration.missingPRPollInterval
    } else {
      configuration.existingPRPollInterval
    }
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
