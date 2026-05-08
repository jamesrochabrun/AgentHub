//
//  ClaudeHookInstallationRecord.swift
//  AgentHub
//
//  SQLite record for Claude approval hook paths AgentHub owns.
//

import Foundation
import GRDB

public struct ClaudeHookInstallationRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public var projectPath: String
  public var installedAt: Date
  public var updatedAt: Date

  public static var databaseTableName: String { "claude_hook_installations" }

  public init(
    projectPath: String,
    installedAt: Date = Date.now,
    updatedAt: Date = Date.now
  ) {
    self.projectPath = projectPath
    self.installedAt = installedAt
    self.updatedAt = updatedAt
  }
}
