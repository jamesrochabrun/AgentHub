//
//  SessionProviderProtocols.swift
//  AgentHub
//
//  Provider-agnostic abstractions for session discovery, monitoring, and search.
//

import Combine
import Foundation

// MARK: - SessionProviderKind

public enum SessionProviderKind: String, CaseIterable, Sendable {
  case claude = "Claude"
  case codex = "Codex"
}

// MARK: - SessionMonitorServiceProtocol

public protocol SessionMonitorServiceProtocol: AnyObject, Sendable {
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> { get }

  @discardableResult
  func addRepository(_ path: String) async -> SelectedRepository?
  func addRepositories(_ paths: [String]) async
  func removeRepository(_ path: String) async
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
