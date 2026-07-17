import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Agent workspace persistence")
struct AgentWorkspacePersistenceTests {
  @Test("Workspace, snapshot, and links round-trip transactionally")
  func workspaceRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryAgentWorkspaceDatabasePath())
    let snapshot = workspaceSnapshot(path: "/tmp/project")
    var workspace = try AgentWorkspaceRecord(
      id: "workspace-1",
      projectPath: "/tmp/project",
      snapshot: snapshot
    )
    let link = AgentWorkspaceSessionLink(
      workspaceId: workspace.id,
      provider: .claude,
      sessionId: "session-1",
      origin: .explicit
    )

    try await store.saveAgentWorkspace(workspace, links: [link])

    let loaded = try await store.loadAgentWorkspaces()
    #expect(loaded.count == 1)
    #expect(try loaded[0].decodedSnapshot() == snapshot)
    let loadedLinks = try await store.loadAgentWorkspaceSessionLinks()
    #expect(loadedLinks.count == 1)
    #expect(loadedLinks.first?.workspaceId == link.workspaceId)
    #expect(loadedLinks.first?.provider == link.provider)
    #expect(loadedLinks.first?.sessionId == link.sessionId)
    #expect(loadedLinks.first?.origin == link.origin)

    let updatedSnapshot = TerminalWorkspaceSnapshot(
      panels: snapshot.panels + [
        TerminalWorkspacePanelSnapshot(
          role: .auxiliary,
          tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: "/tmp/project")]
        )
      ]
    )
    try workspace.updateSnapshot(updatedSnapshot)
    try await store.saveAgentWorkspace(workspace, links: [])

    #expect(try await store.loadAgentWorkspaceSessionLinks().isEmpty)
    #expect(try await store.loadAgentWorkspaces().first?.decodedSnapshot() == updatedSnapshot)
  }

  @Test("A provider session can belong to only one workspace")
  func sessionLinkHasSingleWorkspaceOwner() async throws {
    let store = try SessionMetadataStore(path: temporaryAgentWorkspaceDatabasePath())
    let first = try AgentWorkspaceRecord(
      id: "workspace-1",
      projectPath: "/tmp/project",
      snapshot: workspaceSnapshot(path: "/tmp/project")
    )
    let second = try AgentWorkspaceRecord(
      id: "workspace-2",
      projectPath: "/tmp/project",
      snapshot: workspaceSnapshot(path: "/tmp/project")
    )
    try await store.saveAgentWorkspace(
      first,
      links: [
        AgentWorkspaceSessionLink(
          workspaceId: first.id,
          provider: .codex,
          sessionId: "session-1",
          origin: .detected
        )
      ]
    )

    var didThrow = false
    do {
      try await store.saveAgentWorkspace(
        second,
        links: [
          AgentWorkspaceSessionLink(
            workspaceId: second.id,
            provider: .codex,
            sessionId: "session-1",
            origin: .explicit
          )
        ]
      )
    } catch {
      didThrow = true
    }
    #expect(didThrow)
  }

  @Test("Deleting a workspace removes links but not session metadata")
  func workspaceDeletePreservesSessionMetadata() async throws {
    let store = try SessionMetadataStore(path: temporaryAgentWorkspaceDatabasePath())
    try await store.setCustomName("Historical Session", for: "session-1")
    let workspace = try AgentWorkspaceRecord(
      id: "workspace-1",
      projectPath: "/tmp/project",
      snapshot: workspaceSnapshot(path: "/tmp/project")
    )
    try await store.saveAgentWorkspace(
      workspace,
      links: [
        AgentWorkspaceSessionLink(
          workspaceId: workspace.id,
          provider: .claude,
          sessionId: "session-1",
          origin: .explicit
        )
      ]
    )

    try await store.deleteAgentWorkspace(id: workspace.id)

    #expect(try await store.loadAgentWorkspaces().isEmpty)
    #expect(try await store.loadAgentWorkspaceSessionLinks().isEmpty)
    #expect(try await store.getCustomName(for: "session-1") == "Historical Session")
  }

  @Test("v12 migration preserves every v11 table")
  func migrationPreservesV11Tables() async throws {
    let path = temporaryAgentWorkspaceDatabasePath()
    do {
      _ = try SessionMetadataStore(path: path)
    }

    let dbQueue = try DatabaseQueue(path: path)
    try await dbQueue.write { db in
      let now = Date(timeIntervalSince1970: 1_000)
      let snapshotData = try JSONEncoder().encode(workspaceSnapshot(path: "/tmp/project"))
      let emptyStrings = try JSONEncoder().encode([String]())
      let emptyExpansion = try JSONEncoder().encode([String: Bool]())

      try db.execute(
        sql: "INSERT INTO session_metadata VALUES (?, ?, ?, ?, ?)",
        arguments: ["session-1", "Session", now, now, true]
      )
      try db.execute(
        sql: "INSERT INTO session_repo_mapping VALUES (?, ?, ?, ?)",
        arguments: ["session-1", "/tmp/project", "/tmp/project", now]
      )
      try db.execute(
        sql: "INSERT INTO ai_config VALUES (?, ?, ?, ?, ?, ?, ?)",
        arguments: ["claude", "", "", "", "", "", now]
      )
      try db.execute(
        sql: "INSERT INTO terminal_workspaces VALUES (?, ?, ?, ?, ?)",
        arguments: ["claude", "session-1", EmbeddedTerminalBackend.ghostty.rawValue, snapshotData, now]
      )
      try db.execute(
        sql: "INSERT INTO session_workspace_state VALUES (?, ?, ?, ?, ?, ?)",
        arguments: ["claude", emptyStrings, emptyStrings, emptyExpansion, now, emptyStrings]
      )
      try db.execute(
        sql: "INSERT INTO managed_processes (pid, kind, terminalKey, registeredAt, updatedAt) VALUES (?, ?, ?, ?, ?)",
        arguments: [42, ManagedProcessKind.auxiliaryShell.rawValue, "terminal-1", now, now]
      )
      try db.execute(
        sql: "INSERT INTO claude_hook_installations VALUES (?, ?, ?)",
        arguments: ["/tmp/project", now, now]
      )
      try db.execute(
        sql: "INSERT INTO session_relationships VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        arguments: ["claude", "session-1", "codex", "session-2", "accessoryChild", "explicit", now, now]
      )
      try db.execute(
        sql: "INSERT INTO project_simulator_preferences VALUES (?, ?, ?, ?)",
        arguments: ["/tmp/project", "SIM-1", "simulator", now]
      )

      try db.execute(sql: "DROP TABLE workspace_session_links")
      try db.execute(sql: "DROP TABLE agent_workspaces")
      try db.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
        arguments: ["v12_create_agent_workspaces"]
      )
    }

    _ = try SessionMetadataStore(path: path)

    try await dbQueue.read { db in
      let preservedTables = [
        "session_metadata",
        "session_repo_mapping",
        "ai_config",
        "terminal_workspaces",
        "session_workspace_state",
        "managed_processes",
        "claude_hook_installations",
        "session_relationships",
        "project_simulator_preferences"
      ]
      for table in preservedTables {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
        #expect(count == 1)
      }
      #expect(try db.tableExists("agent_workspaces"))
      #expect(try db.tableExists("workspace_session_links"))
    }
  }
}

private func workspaceSnapshot(path: String) -> TerminalWorkspaceSnapshot {
  TerminalWorkspaceSnapshot(
    panels: [
      TerminalWorkspacePanelSnapshot(
        role: .primary,
        tabs: [TerminalWorkspaceTabSnapshot(role: .shell, workingDirectory: path)]
      )
    ]
  )
}

private func temporaryAgentWorkspaceDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_agent_workspaces_\(UUID().uuidString).sqlite")
    .path
}
