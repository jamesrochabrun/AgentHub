//
//  SessionWorkspaceState.swift
//  AgentHub
//

import Foundation

/// Persisted workspace/session selection state for one CLI provider.
public struct SessionWorkspaceState: Codable, Equatable, Sendable {
  public var selectedRepositoryPaths: [String]
  public var monitoredSessionIds: [String]
  public var ownedWorktreePaths: [String]
  public var expansionState: [String: Bool]

  public init(
    selectedRepositoryPaths: [String] = [],
    monitoredSessionIds: [String] = [],
    ownedWorktreePaths: [String] = [],
    expansionState: [String: Bool] = [:]
  ) {
    self.selectedRepositoryPaths = selectedRepositoryPaths
    self.monitoredSessionIds = monitoredSessionIds
    self.ownedWorktreePaths = ownedWorktreePaths
    self.expansionState = expansionState
  }
}
