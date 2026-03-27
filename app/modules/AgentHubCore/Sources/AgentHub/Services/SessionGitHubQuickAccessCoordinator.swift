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

struct SessionGitHubQuickAccessCoordinatorConfiguration: Sendable {
  var missingPRPollInterval: TimeInterval = 30
  var existingPRPollInterval: TimeInterval = 120
  var idleTimeout: TimeInterval = 5 * 60
  var errorBackoff: [TimeInterval] = [60, 120, 300]
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
    var pollTask: Task<Void, Never>?
    var subscribers: [UUID: AsyncStream<GitHubPullRequest?>.Continuation] = [:]
  }

  private let service: any GitHubCLIServiceProtocol
  private let configuration: SessionGitHubQuickAccessCoordinatorConfiguration
  private var entries: [String: Entry] = [:]
  private var subscriptionKeys: [UUID: String] = [:]

  init(
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
    entry.isTerminallyPaused = false
    entries[repositoryKey] = entry
    subscriptionKeys[subscriptionID] = repositoryKey

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
      entry.pollTask?.cancel()
      entry.pollTask = nil
    }

    entries[repositoryKey] = entry
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
    let shouldReactivate = !entry.subscribers.isEmpty && (entry.pollTask == nil || entry.isTerminallyPaused)
    entry.isTerminallyPaused = false
    entries[repositoryKey] = entry

    if shouldReactivate {
      scheduleRefreshIfNeeded(for: repositoryKey, forceImmediate: true)
    }
  }

  // MARK: - Scheduling

  private func scheduleRefreshIfNeeded(for repositoryKey: String, forceImmediate: Bool) {
    guard var entry = entries[repositoryKey], !entry.subscribers.isEmpty else { return }

    if !forceImmediate, entry.pollTask != nil {
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

    entry.pollTask?.cancel()
    entry.pollTask = Task {
      let delay = Self.duration(for: interval)
      if interval > 0 {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled else { return }
      await self.executeScheduledRefresh(for: repositoryKey)
    }
    entries[repositoryKey] = entry
  }

  private func executeScheduledRefresh(for repositoryKey: String) async {
    guard var entry = entries[repositoryKey] else { return }
    entry.pollTask = nil
    entries[repositoryKey] = entry

    guard !entry.subscribers.isEmpty else { return }

    if entry.lastRefreshAt != nil, !canAutoRefresh(entry, now: .now) {
      return
    }

    let refreshResult = await refreshCurrentBranchPR(at: entry.projectPath)

    guard var refreshedEntry = entries[repositoryKey] else { return }
    refreshedEntry.pollTask = nil
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

      if canAutoRefresh(refreshedEntry, now: .now) {
        scheduleRefreshIfNeeded(for: repositoryKey, forceImmediate: false)
      }

    case .failure(let error):
      if isTerminal(error) {
        refreshedEntry.isTerminallyPaused = true
        refreshedEntry.consecutiveErrorCount = 0
        entries[repositoryKey] = refreshedEntry
        return
      }

      refreshedEntry.consecutiveErrorCount += 1
      refreshedEntry.isTerminallyPaused = false
      entries[repositoryKey] = refreshedEntry

      if canAutoRefresh(refreshedEntry, now: .now) {
        scheduleBackoffRefresh(for: repositoryKey, errorCount: refreshedEntry.consecutiveErrorCount)
      }
    }
  }

  private func scheduleBackoffRefresh(for repositoryKey: String, errorCount: Int) {
    guard var entry = entries[repositoryKey], !entry.subscribers.isEmpty else { return }

    let intervals = configuration.errorBackoff
    let index = min(max(0, errorCount - 1), max(0, intervals.count - 1))
    let interval = intervals[index]

    entry.pollTask?.cancel()
    entry.pollTask = Task {
      let delay = Self.duration(for: interval)
      if interval > 0 {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled else { return }
      await self.executeScheduledRefresh(for: repositoryKey)
    }
    entries[repositoryKey] = entry
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
