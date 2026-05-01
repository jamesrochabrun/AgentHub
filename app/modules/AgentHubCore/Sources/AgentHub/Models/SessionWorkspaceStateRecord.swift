//
//  SessionWorkspaceStateRecord.swift
//  AgentHub
//

import Foundation
import GRDB

/// SQLite representation of workspace/session selection state for one provider.
public struct SessionWorkspaceStateRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
  public static var databaseTableName: String { "session_workspace_state" }

  public var provider: String
  public var selectedRepositoryPathsData: Data
  public var monitoredSessionIdsData: Data
  public var expansionStateData: Data
  public var updatedAt: Date

  public init(
    provider: String,
    state: SessionWorkspaceState,
    updatedAt: Date = Date()
  ) throws {
    self.provider = provider
    self.selectedRepositoryPathsData = try JSONEncoder().encode(state.selectedRepositoryPaths)
    self.monitoredSessionIdsData = try JSONEncoder().encode(state.monitoredSessionIds)
    self.expansionStateData = try JSONEncoder().encode(state.expansionState)
    self.updatedAt = updatedAt
  }

  public func decodedState() -> SessionWorkspaceState {
    SessionWorkspaceState(
      selectedRepositoryPaths: (try? JSONDecoder().decode([String].self, from: selectedRepositoryPathsData)) ?? [],
      monitoredSessionIds: (try? JSONDecoder().decode([String].self, from: monitoredSessionIdsData)) ?? [],
      expansionState: (try? JSONDecoder().decode([String: Bool].self, from: expansionStateData)) ?? [:]
    )
  }
}
