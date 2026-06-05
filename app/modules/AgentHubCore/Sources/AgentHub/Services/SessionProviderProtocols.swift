//
//  SessionProviderProtocols.swift
//  AgentHub
//
//  Provider-agnostic abstractions for session discovery, monitoring, and search.
//

import Combine
import Foundation

public extension SessionProviderKind {
  init(cliMode: CLICommandMode) {
    switch cliMode {
    case .claude:
      self = .claude
    case .codex:
      self = .codex
    }
  }
}

// MARK: - SessionMonitorServiceProtocol

public struct WorktreeSessionImportPage: Sendable, Equatable {
  public let sessions: [CLISession]
  public let hasMore: Bool

  public init(sessions: [CLISession], hasMore: Bool) {
    self.sessions = sessions
    self.hasMore = hasMore
  }
}

public protocol SessionMonitorServiceProtocol: AnyObject, Sendable {
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> { get }

  /// Adds a repository and returns it when a refresh was performed.
  /// Returns nil for duplicate/no-op adds.
  @discardableResult
  func addRepository(_ path: String) async -> SelectedRepository?
  func addRepositories(_ paths: [String]) async
  func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository]
  func loadSessions(ids: Set<String>) async -> [CLISession]
  func loadLatestSessions(
    inWorktreePath worktreePath: String,
    excludingSessionIds: Set<String>,
    limit: Int
  ) async -> WorktreeSessionImportPage
  func removeRepository(_ path: String) async
  func setOwnedWorktreePaths(_ paths: Set<String>) async
  func setFocusedSessionIds(_ ids: Set<String>) async
  func registerWorktree(_ worktree: WorktreeBranch, parentRepositoryPath: String) async
  func getSelectedRepositories() async -> [SelectedRepository]
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async
  func refreshSessions(skipWorktreeRedetection: Bool) async
}

// MARK: - Defaults

public extension SessionMonitorServiceProtocol {
  func refreshSessions() async {
    await refreshSessions(skipWorktreeRedetection: false)
  }

  /// Default implementation: loops addRepository one at a time
  func addRepositories(_ paths: [String]) async {
    for path in paths {
      await addRepository(path)
    }
  }

  func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository] {
    await addRepositories(paths)
    return await getSelectedRepositories()
  }

  func loadSessions(ids: Set<String>) async -> [CLISession] {
    let repositories = await getSelectedRepositories()
    return repositories
      .flatMap { $0.worktrees }
      .flatMap { $0.sessions }
      .filter { ids.contains($0.id) }
  }

  func loadLatestSessions(
    inWorktreePath worktreePath: String,
    excludingSessionIds: Set<String>,
    limit: Int
  ) async -> WorktreeSessionImportPage {
    guard limit > 0 else {
      return WorktreeSessionImportPage(sessions: [], hasMore: false)
    }

    let normalizedWorktreePath = WorktreeModuleResolver.normalizedDirectoryPath(worktreePath)
    let sessions = await getSelectedRepositories()
      .flatMap(\.worktrees)
      .flatMap(\.sessions)
      .filter { session in
        guard !excludingSessionIds.contains(session.id) else { return false }
        let projectPath = WorktreeModuleResolver.normalizedDirectoryPath(session.projectPath)
        return projectPath == normalizedWorktreePath || projectPath.hasPrefix(normalizedWorktreePath + "/")
      }
      .sorted { $0.lastActivityAt > $1.lastActivityAt }

    return WorktreeSessionImportPage(
      sessions: Array(sessions.prefix(limit)),
      hasMore: sessions.count > limit
    )
  }

  func registerWorktree(_ worktree: WorktreeBranch, parentRepositoryPath: String) async {}

  func setOwnedWorktreePaths(_ paths: Set<String>) async {}

  func setFocusedSessionIds(_ ids: Set<String>) async {}
}

// MARK: - SessionFileWatcherProtocol

public protocol SessionFileWatcherProtocol: AnyObject, Sendable {
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> { get }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async
  func stopMonitoring(sessionId: String) async
  func getState(sessionId: String) async -> SessionMonitorState?
  func refreshState(sessionId: String) async
  func setApprovalTimeout(_ seconds: Int) async
}

// MARK: - SessionSearchServiceProtocol

public protocol SessionSearchServiceProtocol: AnyObject, Sendable {
  func search(query: String, filterPath: String?) async -> [SessionSearchResult]
  func rebuildIndex() async
  func indexedSessionCount() async -> Int
}
