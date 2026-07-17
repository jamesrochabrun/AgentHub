//
//  AgentWorkspaceStoreProtocol.swift
//  AgentHub
//
//  Persistence abstraction for provider-neutral terminal workspaces.
//

import Foundation

public protocol AgentWorkspaceStoreProtocol: Sendable {
  func loadAgentWorkspaces() async throws -> [AgentWorkspaceRecord]
  func loadAgentWorkspaceSessionLinks() async throws -> [AgentWorkspaceSessionLink]

  func saveAgentWorkspace(
    _ workspace: AgentWorkspaceRecord,
    links: [AgentWorkspaceSessionLink]
  ) async throws

  func deleteAgentWorkspace(id: String) async throws
}
