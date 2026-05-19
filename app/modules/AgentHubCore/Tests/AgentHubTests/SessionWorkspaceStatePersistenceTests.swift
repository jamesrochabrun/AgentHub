import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Session workspace state persistence")
struct SessionWorkspaceStatePersistenceTests {

  @Test("Workspace state round-trips and is provider scoped")
  func workspaceStateRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryWorkspaceStateDatabasePath())
    let state = SessionWorkspaceState(
      selectedRepositoryPaths: ["/tmp/project-a", "/tmp/project-b"],
      monitoredSessionIds: ["session-1", "session-2"],
      ownedWorktreePaths: ["/tmp/project-a/worktrees/feature"],
      expansionState: [
        "repo:/tmp/project-a": true,
        "wt:/tmp/project-a/worktrees/feature": false
      ]
    )

    try await store.saveWorkspaceState(state, for: .claude)

    #expect(store.getWorkspaceStateSync(for: .claude) == state)
    #expect(store.getWorkspaceStateSync(for: .codex) == SessionWorkspaceState())
  }

  @Test("Owned worktree migration preserves existing workspace state")
  func ownedWorktreeMigrationPreservesExistingWorkspaceState() async throws {
    let path = temporaryWorkspaceStateDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)
    let selectedRepositoryPathsData = try JSONEncoder().encode(["/tmp/project"])
    let monitoredSessionIdsData = try JSONEncoder().encode(["session-1"])
    let expansionStateData = try JSONEncoder().encode(["repo:/tmp/project": true])

    try dbQueue.write { db in
      try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      for identifier in SessionMetadataStore.migrationIdentifiers.dropLast() {
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
      }

      try db.create(table: "session_workspace_state") { t in
        t.column("provider", .text).primaryKey()
        t.column("selectedRepositoryPathsData", .blob).notNull()
        t.column("monitoredSessionIdsData", .blob).notNull()
        t.column("expansionStateData", .blob).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
      try db.execute(
        sql: """
        INSERT INTO session_workspace_state
        (provider, selectedRepositoryPathsData, monitoredSessionIdsData, expansionStateData, updatedAt)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [
          SessionProviderKind.claude.rawValue,
          selectedRepositoryPathsData,
          monitoredSessionIdsData,
          expansionStateData,
          Date(timeIntervalSince1970: 1_000)
        ]
      )
    }

    let store = try SessionMetadataStore(path: path)
    #expect(
      store.getWorkspaceStateSync(for: .claude) == SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1"],
        ownedWorktreePaths: [],
        expansionState: ["repo:/tmp/project": true]
      )
    )
  }

  @Test("Clear all removes workspace state")
  func clearAllRemovesWorkspaceState() async throws {
    let store = try SessionMetadataStore(path: temporaryWorkspaceStateDatabasePath())
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: ["/tmp/project"],
        monitoredSessionIds: ["session-1"],
        expansionState: ["repo:/tmp/project": true]
      ),
      for: .claude
    )

    try await store.clearAll()

    #expect(store.getWorkspaceStateSync(for: .claude) == SessionWorkspaceState())
  }
}

private func temporaryWorkspaceStateDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_workspace_state_\(UUID().uuidString).sqlite")
    .path
}
