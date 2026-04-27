//
//  TerminalWorkspaceRecord.swift
//  AgentHub
//
//  SQLite record for persisted embedded terminal workspaces.
//

import Foundation
import GRDB

public struct TerminalWorkspaceRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
  public var provider: String
  public var sessionId: String
  public var backend: Int
  public var snapshotData: Data
  public var updatedAt: Date

  public static var databaseTableName: String { "terminal_workspaces" }

  public init(
    provider: String,
    sessionId: String,
    backend: Int,
    snapshotData: Data,
    updatedAt: Date = Date()
  ) {
    self.provider = provider
    self.sessionId = sessionId
    self.backend = backend
    self.snapshotData = snapshotData
    self.updatedAt = updatedAt
  }
}
