//
//  AgentWorkspaceRecord.swift
//  AgentHub
//
//  SQLite record for a provider-neutral terminal workspace.
//

import Foundation
import GRDB

public struct AgentWorkspaceRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
  public var id: String
  public var projectPath: String
  public var customName: String?
  public var backend: Int
  public var snapshotData: Data
  public var createdAt: Date
  public var updatedAt: Date

  public static var databaseTableName: String { "agent_workspaces" }

  public init(
    id: String = UUID().uuidString,
    projectPath: String,
    customName: String? = nil,
    backend: EmbeddedTerminalBackend = .ghostty,
    snapshot: TerminalWorkspaceSnapshot,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) throws {
    self.id = id
    self.projectPath = projectPath
    self.customName = customName
    self.backend = backend.rawValue
    snapshotData = try JSONEncoder().encode(snapshot)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var terminalBackend: EmbeddedTerminalBackend {
    EmbeddedTerminalBackend(rawValue: backend) ?? .ghostty
  }

  public func decodedSnapshot() throws -> TerminalWorkspaceSnapshot {
    try JSONDecoder().decode(TerminalWorkspaceSnapshot.self, from: snapshotData)
  }

  public mutating func updateSnapshot(_ snapshot: TerminalWorkspaceSnapshot) throws {
    snapshotData = try JSONEncoder().encode(snapshot)
    updatedAt = .now
  }
}
