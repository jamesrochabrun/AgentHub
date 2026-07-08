import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Project simulator preference persistence")
struct ProjectSimulatorPreferenceTests {

  @Test("Preference round-trips per project path")
  func preferenceRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryPreferenceDatabasePath())

    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: "/tmp/project-a",
        deviceIdentifier: "UDID-A",
        kind: .simulator
      )
    )
    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: "/tmp/project-b",
        deviceIdentifier: "PHONE-1",
        kind: .physical
      )
    )

    let preferences = try await store.getProjectSimulatorPreferences()
    let byPath = Dictionary(uniqueKeysWithValues: preferences.map { ($0.projectPath, $0) })
    #expect(byPath.count == 2)
    #expect(byPath["/tmp/project-a"]?.deviceIdentifier == "UDID-A")
    #expect(byPath["/tmp/project-a"]?.kind == .simulator)
    #expect(byPath["/tmp/project-b"]?.deviceIdentifier == "PHONE-1")
    #expect(byPath["/tmp/project-b"]?.kind == .physical)
  }

  @Test("Saving again replaces the row for the same project path")
  func preferenceReplacesOnConflict() async throws {
    let store = try SessionMetadataStore(path: temporaryPreferenceDatabasePath())

    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: "/tmp/project",
        deviceIdentifier: "UDID-OLD",
        kind: .simulator
      )
    )
    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: "/tmp/project",
        deviceIdentifier: "PHONE-NEW",
        kind: .physical
      )
    )

    let preferences = try await store.getProjectSimulatorPreferences()
    #expect(preferences.count == 1)
    #expect(preferences.first?.deviceIdentifier == "PHONE-NEW")
    #expect(preferences.first?.kind == .physical)
  }

  @Test("Delete removes only the targeted project path")
  func preferenceDelete() async throws {
    let store = try SessionMetadataStore(path: temporaryPreferenceDatabasePath())

    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: "/tmp/project-a",
        deviceIdentifier: "UDID-A",
        kind: .simulator
      )
    )
    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: "/tmp/project-b",
        deviceIdentifier: "UDID-B",
        kind: .simulator
      )
    )

    try await store.deleteProjectSimulatorPreference(projectPath: "/tmp/project-a")

    let preferences = try await store.getProjectSimulatorPreferences()
    #expect(preferences.map(\.projectPath) == ["/tmp/project-b"])
  }

  @Test("Clear all removes preferences")
  func clearAllRemovesPreferences() async throws {
    let store = try SessionMetadataStore(path: temporaryPreferenceDatabasePath())
    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: "/tmp/project",
        deviceIdentifier: "UDID",
        kind: .simulator
      )
    )

    try await store.clearAll()

    #expect(try await store.getProjectSimulatorPreferences().isEmpty)
  }

  @Test("v11 migration preserves existing metadata")
  func migrationPreservesExistingMetadata() async throws {
    let path = temporaryPreferenceDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)

    try await dbQueue.write { db in
      try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      for identifier in SessionMetadataStore.migrationIdentifiers.dropLast() {
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
      }

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
        arguments: ["session-1", "My Session", Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 1_000), true]
      )
    }

    let store = try SessionMetadataStore(path: path)
    #expect(try await store.getCustomName(for: "session-1") == "My Session")
    #expect(try await store.getPinnedSessionIds() == ["session-1"])
    #expect(try await store.getProjectSimulatorPreferences().isEmpty)

    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: "/tmp/project",
        deviceIdentifier: "UDID",
        kind: .simulator
      )
    )
    #expect(try await store.getProjectSimulatorPreferences().count == 1)
  }
}

private func temporaryPreferenceDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_project_simulator_prefs_\(UUID().uuidString).sqlite")
    .path
}
