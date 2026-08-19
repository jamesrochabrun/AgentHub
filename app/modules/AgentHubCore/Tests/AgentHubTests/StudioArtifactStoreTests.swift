import AgentHubCLIKit
import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Studio artifact store")
struct StudioArtifactStoreTests {
  @Test("An artifact round-trips through SQLite with its variants intact")
  func roundTrips() async throws {
    let store = try SessionMetadataStore(path: temporaryPath())
    let artifact = makeStudioCanvas(id: "c1")
    try await store.saveStudioArtifact(StudioArtifactRecord(artifact: artifact, projectPath: "/tmp/project", sessionId: "s1"))

    let stored = try await store.getStudioArtifacts(forProjectPath: "/tmp/project")
    #expect(stored.count == 1)
    #expect(try stored.first?.decodedArtifact() == artifact)
    #expect(stored.first?.kind == "canvas")
  }

  @Test("Re-saving the same id replaces; projects are isolated; both providers share a project")
  func upsertAndScoping() async throws {
    let store = try SessionMetadataStore(path: temporaryPath())
    try await store.saveStudioArtifact(StudioArtifactRecord(artifact: makeStudioCanvas(id: "c1", title: "v1"), projectPath: "/p", sessionId: "s1"))
    try await store.saveStudioArtifact(StudioArtifactRecord(artifact: makeStudioCanvas(id: "c1", title: "v2"), projectPath: "/p", sessionId: "s1"))
    try await store.saveStudioArtifact(StudioArtifactRecord(artifact: makeStudioDocument(id: "d1", provider: .codex), projectPath: "/p/", sessionId: "codex"))
    try await store.saveStudioArtifact(StudioArtifactRecord(artifact: makeStudioDocument(id: "other"), projectPath: "/q", sessionId: "s9"))

    let p = try await store.getStudioArtifacts(forProjectPath: "/p")
    #expect(Set(p.map(\.id)) == ["c1", "d1"])
    #expect(try p.first { $0.id == "c1" }?.decodedArtifact().title == "v2")
    #expect(try await store.getStudioArtifacts(forProjectPath: "/q").map(\.id) == ["other"])
    #expect(try await store.getAllStudioArtifacts().count == 3)

    try await store.deleteStudioArtifact(id: "d1")
    try await store.deleteAllStudioArtifacts(forProjectPath: "/q")
    #expect(try await store.getAllStudioArtifacts().map(\.id) == ["c1"])
  }

  @Test("v18 migration preserves existing metadata")
  func v18MigrationPreservesExistingMetadata() async throws {
    let path = temporaryPath()
    let dbQueue = try DatabaseQueue(path: path)

    try await dbQueue.write { db in
      try seedMigrationBaseline(before: SessionMetadataStore.MigrationID.createStudioArtifacts, in: db)
      try db.create(table: "session_metadata") { t in
        t.column("sessionId", .text).primaryKey()
        t.column("customName", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("isPinned", .boolean).notNull().defaults(to: false)
      }
      try db.execute(
        sql: "INSERT INTO session_metadata (sessionId, customName, createdAt, updatedAt, isPinned) VALUES (?, ?, ?, ?, ?)",
        arguments: ["legacy-session", "legacy-name", Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 2_000), true]
      )
      try db.create(table: "session_measurements") { t in
        t.column("id", .text).primaryKey(onConflict: .replace)
        t.column("sessionId", .text).notNull().indexed()
        t.column("provider", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("payloadVersion", .integer).notNull()
        t.column("payloadData", .blob).notNull()
        t.column("projectPath", .text).notNull().defaults(to: "")
      }
    }

    let store = try SessionMetadataStore(path: path)
    #expect(try await store.getCustomName(for: "legacy-session") == "legacy-name")
    #expect(try await store.getPinnedSessionIds() == ["legacy-session"])
    #expect(try await store.getStudioArtifacts(forProjectPath: "/tmp/project").isEmpty)
    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project").isEmpty)
  }

  private func temporaryPath() -> String {
    FileManager.default.temporaryDirectory
      .appending(path: "studio_artifacts_\(UUID().uuidString).sqlite")
      .path
  }
}
