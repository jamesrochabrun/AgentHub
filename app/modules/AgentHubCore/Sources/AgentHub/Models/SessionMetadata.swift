//
//  SessionMetadata.swift
//  AgentHub
//
//  User-provided metadata for sessions stored in SQLite
//

import Foundation
import GRDB

/// Represents user-provided metadata for a session
/// Stored in SQLite for persistence across app launches
public struct SessionMetadata: Codable, Sendable, FetchableRecord, PersistableRecord {

  /// The session UUID (primary key, matches CLISession.id)
  public var sessionId: String

  /// User-provided name for the session (optional)
  public var customName: String?

  /// Whether the session is archived (hidden from main view)
  public var isArchived: Bool

  /// When the metadata was created
  public var createdAt: Date

  /// When the metadata was last updated
  public var updatedAt: Date

  // MARK: - GRDB Configuration

  public static var databaseTableName: String { "session_metadata" }

  // MARK: - Initialization

  public init(
    sessionId: String,
    customName: String? = nil,
    isArchived: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.sessionId = sessionId
    self.customName = customName
    self.isArchived = isArchived
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
