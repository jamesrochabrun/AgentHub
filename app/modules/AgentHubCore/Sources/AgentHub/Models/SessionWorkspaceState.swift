//
//  SessionWorkspaceState.swift
//  AgentHub
//

import Foundation

/// Persisted workspace/session selection state for one CLI provider.
public struct SessionWorkspaceState: Codable, Equatable, Sendable {
  public var selectedRepositoryPaths: [String]
  public var monitoredSessionIds: [String]
  public var expansionState: [String: Bool]

  public init(
    selectedRepositoryPaths: [String] = [],
    monitoredSessionIds: [String] = [],
    expansionState: [String: Bool] = [:]
  ) {
    self.selectedRepositoryPaths = selectedRepositoryPaths
    self.monitoredSessionIds = monitoredSessionIds
    self.expansionState = expansionState
  }
}
