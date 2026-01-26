//
//  SessionMetadataStore.swift
//  AgentHub
//
//  Actor-based service for persisting session metadata to SQLite
//

import Foundation
import GRDB

/// Actor-based service for persisting session metadata to SQLite
/// Uses GRDB for database operations with async/await support
public actor SessionMetadataStore {

  // MARK: - Properties

  private let dbQueue: DatabaseQueue

  // MARK: - Initialization

  /// Creates a new metadata store at the default location
  /// Database is stored in ~/Library/Application Support/AgentHub/session_metadata.sqlite
  public init() throws {
    let appSupportURL = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!

    let agentHubDir = appSupportURL.appendingPathComponent("AgentHub", isDirectory: true)
    try FileManager.default.createDirectory(
      at: agentHubDir,
      withIntermediateDirectories: true
    )

    let dbPath = agentHubDir.appendingPathComponent("session_metadata.sqlite")
    dbQueue = try DatabaseQueue(path: dbPath.path)

    try migrator.migrate(dbQueue)
  }

  /// Creates a store with a custom database path (for testing)
  public init(path: String) throws {
    dbQueue = try DatabaseQueue(path: path)
    try migrator.migrate(dbQueue)
  }

  // MARK: - Migrations

  private nonisolated var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("v1_create_session_metadata") { db in
      try db.create(table: "session_metadata") { t in
        t.column("sessionId", .text).primaryKey()
        t.column("customName", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
    }

    return migrator
  }

  // MARK: - Public API

  /// Gets the custom name for a session, if one exists
  public func getCustomName(for sessionId: String) throws -> String? {
    try dbQueue.read { db in
      try SessionMetadata
        .filter(Column("sessionId") == sessionId)
        .fetchOne(db)?
        .customName
    }
  }

  /// Sets the custom name for a session
  /// Creates new record if none exists, updates if it does
  public func setCustomName(_ name: String?, for sessionId: String) throws {
    try dbQueue.write { db in
      if var existing = try SessionMetadata.fetchOne(db, key: sessionId) {
        existing.customName = name
        existing.updatedAt = Date()
        try existing.update(db)
      } else if let name = name, !name.isEmpty {
        let metadata = SessionMetadata(
          sessionId: sessionId,
          customName: name
        )
        try metadata.insert(db)
      }
    }
  }

  /// Gets all metadata for multiple sessions at once (batch fetch)
  public func getMetadata(for sessionIds: [String]) throws -> [String: SessionMetadata] {
    try dbQueue.read { db in
      let records = try SessionMetadata
        .filter(sessionIds.contains(Column("sessionId")))
        .fetchAll(db)

      return Dictionary(uniqueKeysWithValues: records.map { ($0.sessionId, $0) })
    }
  }

  /// Deletes metadata for a session
  public func deleteMetadata(for sessionId: String) throws {
    try dbQueue.write { db in
      _ = try SessionMetadata.deleteOne(db, key: sessionId)
    }
  }

  /// Clears all metadata (for testing/reset)
  public func clearAll() throws {
    try dbQueue.write { db in
      _ = try SessionMetadata.deleteAll(db)
    }
  }
}
