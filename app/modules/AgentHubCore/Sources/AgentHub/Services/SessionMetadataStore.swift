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

    migrator.registerMigration("v2_create_session_repo_mapping") { db in
      try db.create(table: "session_repo_mapping") { t in
        t.column("sessionId", .text).primaryKey()
        t.column("parentRepoPath", .text).notNull().indexed()
        t.column("worktreePath", .text).notNull()
        t.column("assignedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration("v3_create_ai_config") { db in
      try db.create(table: "ai_config") { t in
        t.column("provider", .text).primaryKey()
        t.column("defaultModel", .text).notNull().defaults(to: "")
        t.column("effortLevel", .text).notNull().defaults(to: "")
        t.column("allowedTools", .text).notNull().defaults(to: "")
        t.column("disallowedTools", .text).notNull().defaults(to: "")
        t.column("approvalPolicy", .text).notNull().defaults(to: "")
        t.column("updatedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration("v4_add_pinned") { db in
      try db.alter(table: "session_metadata") { t in
        t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
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

  /// Sets the pinned state for a session
  /// Creates new record if none exists, updates if it does
  public func setPinned(_ isPinned: Bool, for sessionId: String) throws {
    try dbQueue.write { db in
      if var existing = try SessionMetadata.fetchOne(db, key: sessionId) {
        existing.isPinned = isPinned
        existing.updatedAt = Date()
        try existing.update(db)
      } else if isPinned {
        let metadata = SessionMetadata(
          sessionId: sessionId,
          isPinned: true
        )
        try metadata.insert(db)
      }
    }
  }

  /// Gets all pinned session IDs
  public func getPinnedSessionIds() throws -> Set<String> {
    try dbQueue.read { db in
      let records = try SessionMetadata
        .filter(Column("isPinned") == true)
        .fetchAll(db)
      return Set(records.map(\.sessionId))
    }
  }

  /// Synchronous read for pinned session IDs — safe to call from non-async contexts.
  public nonisolated func getPinnedSessionIdsSync() -> Set<String> {
    (try? dbQueue.read { db in
      let records = try SessionMetadata
        .filter(Column("isPinned") == true)
        .fetchAll(db)
      return Set(records.map(\.sessionId))
    }) ?? []
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
      _ = try AIConfigRecord.deleteAll(db)
      _ = try SessionRepoMapping.deleteAll(db)
      _ = try SessionMetadata.deleteAll(db)
    }
  }

  // MARK: - Session Repo Mapping

  /// Gets the repo mapping for a session, if one exists
  public func getRepoMapping(for sessionId: String) throws -> SessionRepoMapping? {
    try dbQueue.read { db in
      try SessionRepoMapping
        .filter(Column("sessionId") == sessionId)
        .fetchOne(db)
    }
  }

  /// Sets the repo mapping for a session
  /// Creates new record if none exists, updates if it does
  public func setRepoMapping(_ mapping: SessionRepoMapping) throws {
    try dbQueue.write { db in
      try mapping.save(db)
    }
  }

  /// Gets repo mappings for multiple sessions at once (batch fetch)
  public func getRepoMappings(for sessionIds: [String]) throws -> [String: SessionRepoMapping] {
    try dbQueue.read { db in
      let records = try SessionRepoMapping
        .filter(sessionIds.contains(Column("sessionId")))
        .fetchAll(db)

      return Dictionary(uniqueKeysWithValues: records.map { ($0.sessionId, $0) })
    }
  }

  /// Deletes repo mapping for a session
  public func deleteRepoMapping(for sessionId: String) throws {
    try dbQueue.write { db in
      _ = try SessionRepoMapping.deleteOne(db, key: sessionId)
    }
  }

  // MARK: - AI Configuration

  /// Gets the AI config for a provider ("claude" or "codex")
  public func getAIConfig(for provider: String) throws -> AIConfigRecord? {
    try dbQueue.read { db in
      try AIConfigRecord
        .filter(Column("provider") == provider)
        .fetchOne(db)
    }
  }

  /// Synchronous read for AI config — safe to call from non-async contexts.
  /// Returns nil if no config is saved or on error.
  public nonisolated func getAIConfigSync(for provider: String) -> AIConfigRecord? {
    try? dbQueue.read { db in
      try AIConfigRecord
        .filter(Column("provider") == provider)
        .fetchOne(db)
    }
  }

  /// Saves or updates the AI config for a provider
  public func saveAIConfig(_ record: AIConfigRecord) throws {
    try dbQueue.write { db in
      var record = record
      record.updatedAt = Date()
      try record.save(db)
    }
  }
}
