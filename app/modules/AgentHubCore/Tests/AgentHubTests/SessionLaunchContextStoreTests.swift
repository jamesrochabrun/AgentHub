import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Session launch context store")
struct SessionLaunchContextStoreTests {

  @Test("Round-trips launch context and reads it synchronously by session id")
  func roundTripsLaunchContext() async throws {
    let path = temporaryLaunchContextDatabasePath()
    let store = try SessionMetadataStore(path: path)

    try await store.saveSessionLaunchContext(SessionLaunchContextRecord(
      sessionId: "session-1",
      provider: "Claude",
      projectPath: "/tmp/project",
      contextText: "<context>x</context>"
    ))

    #expect(store.getSessionLaunchContextTextSync(for: "session-1") == "<context>x</context>")
    #expect(store.getSessionLaunchContextTextSync(for: "missing") == nil)
  }

  @Test("Re-saving a session's context replaces it instead of duplicating")
  func resaveReplaces() async throws {
    let path = temporaryLaunchContextDatabasePath()
    let store = try SessionMetadataStore(path: path)

    try await store.saveSessionLaunchContext(SessionLaunchContextRecord(
      sessionId: "session-1",
      provider: "Claude",
      projectPath: "/tmp/project",
      contextText: "old"
    ))
    try await store.saveSessionLaunchContext(SessionLaunchContextRecord(
      sessionId: "session-1",
      provider: "Claude",
      projectPath: "/tmp/project",
      contextText: "new"
    ))

    #expect(store.getSessionLaunchContextTextSync(for: "session-1") == "new")
  }

  @Test("Saving prunes rows older than the retention window")
  func savePrunesStaleRows() async throws {
    let path = temporaryLaunchContextDatabasePath()
    let store = try SessionMetadataStore(path: path)
    try await store.saveSessionLaunchContext(SessionLaunchContextRecord(
      sessionId: "stale-session",
      provider: "Claude",
      projectPath: "/tmp/project",
      contextText: "stale"
    ))

    // Backdate past the retention window through a second connection — the
    // store API always stamps updatedAt with "now".
    let backdated = Date().addingTimeInterval(-SessionMetadataStore.sessionLaunchContextMaxAge - 60)
    let rawQueue = try DatabaseQueue(path: path)
    try await rawQueue.write { db in
      try db.execute(
        sql: "UPDATE session_launch_context SET updatedAt = ? WHERE sessionId = ?",
        arguments: [backdated, "stale-session"]
      )
    }

    try await store.saveSessionLaunchContext(SessionLaunchContextRecord(
      sessionId: "fresh-session",
      provider: "Claude",
      projectPath: "/tmp/project",
      contextText: "fresh"
    ))

    #expect(store.getSessionLaunchContextTextSync(for: "stale-session") == nil)
    #expect(store.getSessionLaunchContextTextSync(for: "fresh-session") == "fresh")
  }

  @Test("v17 migration preserves existing metadata")
  func v17MigrationPreservesExistingMetadata() async throws {
    let path = temporaryLaunchContextDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)

    try await dbQueue.write { db in
      try seedMigrationBaseline(
        before: SessionMetadataStore.MigrationID.createSessionLaunchContext,
        in: db
      )
      try seedPreLaunchContextBaselineData(in: db)
    }

    let store = try SessionMetadataStore(path: path)

    #expect(try await store.getCustomName(for: "legacy-session") == "legacy-name")
    let profiles = try await store.getContextProfiles(forProjectPath: "/tmp/project")
    #expect(profiles.map(\.id) == ["legacy-profile"])

    // The new table is usable immediately after migrating.
    try await store.saveSessionLaunchContext(SessionLaunchContextRecord(
      sessionId: "post-session",
      provider: "Codex",
      projectPath: "/tmp/project",
      contextText: "<context>post</context>"
    ))
    #expect(store.getSessionLaunchContextTextSync(for: "post-session") == "<context>post</context>")
  }
}

// MARK: - Helpers

/// The v16 shape of the tables asserted on above: session_metadata plus
/// context_profiles with its partial default index.
private func seedPreLaunchContextBaselineData(in db: Database) throws {
  try db.create(table: "session_metadata") { t in
    t.column("sessionId", .text).primaryKey()
    t.column("customName", .text)
    t.column("createdAt", .datetime).notNull()
    t.column("updatedAt", .datetime).notNull()
    t.column("isPinned", .boolean).notNull().defaults(to: false)
  }
  try db.execute(
    sql: """
    INSERT INTO session_metadata (sessionId, customName, createdAt, updatedAt, isPinned)
    VALUES (?, ?, ?, ?, ?)
    """,
    arguments: [
      "legacy-session",
      "legacy-name",
      Date(timeIntervalSince1970: 1_000),
      Date(timeIntervalSince1970: 2_000),
      false,
    ]
  )

  try db.create(table: "context_profiles") { t in
    t.column("id", .text).primaryKey(onConflict: .replace)
    t.column("projectPath", .text).notNull().defaults(to: "").indexed()
    t.column("scope", .text).notNull()
    t.column("name", .text).notNull()
    t.column("isDefault", .boolean).notNull().defaults(to: false)
    t.column("createdAt", .datetime).notNull()
    t.column("updatedAt", .datetime).notNull()
    t.column("payloadVersion", .integer).notNull()
    t.column("payloadData", .blob).notNull()
  }
  try db.execute(sql: """
    CREATE UNIQUE INDEX idx_context_profiles_default
    ON context_profiles(projectPath) WHERE isDefault = 1
    """)
  try db.execute(
    sql: """
    INSERT INTO context_profiles
      (id, projectPath, scope, name, isDefault, createdAt, updatedAt, payloadVersion, payloadData)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """,
    arguments: [
      "legacy-profile",
      "/tmp/project",
      "project",
      "Legacy",
      false,
      Date(timeIntervalSince1970: 1_000),
      Date(timeIntervalSince1970: 2_000),
      1,
      Data("{\"files\":[],\"externalPaths\":[],\"textSnippets\":[],\"instructions\":\"\"}".utf8),
    ]
  )
}

private func temporaryLaunchContextDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "session_launch_context_\(UUID().uuidString).sqlite")
    .path
}
