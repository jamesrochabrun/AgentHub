import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Session metadata migration safety")
struct SessionMetadataMigrationSafetyTests {

  @Test("Existing migration identifiers remain append-only")
  func existingMigrationIdentifiersRemainAppendOnly() {
    let baseline = [
      "v1_create_session_metadata",
      "v2_create_session_repo_mapping",
      "v3_create_ai_config",
      "v4_add_pinned",
      "v5_create_terminal_workspaces",
      "v6_create_session_workspace_state",
      "v7_create_managed_processes",
      "v8_create_claude_hook_installations"
    ]

    #expect(Array(SessionMetadataStore.migrationIdentifiers.prefix(baseline.count)) == baseline)
    #expect(SessionMetadataStore.migrationIdentifiers.count >= baseline.count)
    #expect(Set(SessionMetadataStore.migrationIdentifiers).count == SessionMetadataStore.migrationIdentifiers.count)
  }

  @Test("Migrating current baseline preserves all session metadata tables")
  func migratingCurrentBaselinePreservesAllSessionMetadataTables() async throws {
    let dbPath = temporaryMigrationSafetyDatabasePath()
    let seed = try seedCurrentBaselineDatabase(at: dbPath)

    let store = try SessionMetadataStore(path: dbPath)

    #expect(try await store.getCustomName(for: seed.sessionId) == "Important session")
    #expect(try await store.getPinnedSessionIds() == Set([seed.sessionId]))

    let repoMapping = try await store.getRepoMapping(for: seed.sessionId)
    #expect(repoMapping?.parentRepoPath == seed.parentRepoPath)
    #expect(repoMapping?.worktreePath == seed.worktreePath)

    let aiConfig = try await store.getAIConfig(for: "claude")
    #expect(aiConfig?.defaultModel == "opus")
    #expect(aiConfig?.effortLevel == "high")
    #expect(aiConfig?.allowedTools == "Read, Edit")
    #expect(aiConfig?.disallowedTools == "Bash(rm *)")
    #expect(aiConfig?.approvalPolicy == "on-request")

    #expect(
      store.loadTerminalWorkspace(
        provider: .claude,
        sessionId: seed.sessionId,
        backend: .ghostty
      ) == seed.terminalWorkspace
    )
    #expect(store.getWorkspaceStateSync(for: .claude) == seed.workspaceState)
    #expect(try await store.getManagedProcesses() == [seed.managedProcess])
    #expect(try await store.loadClaudeHookInstalledPaths().isEmpty)
  }
}

private struct MigrationSafetySeed {
  let sessionId: String
  let parentRepoPath: String
  let worktreePath: String
  let terminalWorkspace: TerminalWorkspaceSnapshot
  let workspaceState: SessionWorkspaceState
  let managedProcess: ManagedProcessRecord
}

private func seedCurrentBaselineDatabase(at dbPath: String) throws -> MigrationSafetySeed {
  let sessionId = "session-1"
  let parentRepoPath = "/tmp/project"
  let worktreePath = "/tmp/project/.worktrees/feature"
  let terminalWorkspace = TerminalWorkspaceSnapshot(
    panels: [
      TerminalWorkspacePanelSnapshot(
        role: .primary,
        tabs: [
          TerminalWorkspaceTabSnapshot(
            role: .agent,
            name: "Agent",
            title: "Claude",
            workingDirectory: worktreePath
          )
        ]
      )
    ]
  )
  let workspaceState = SessionWorkspaceState(
    selectedRepositoryPaths: [parentRepoPath],
    monitoredSessionIds: [sessionId],
    expansionState: [
      "repo:\(parentRepoPath)": true,
      "wt:\(worktreePath)": true
    ]
  )
  let managedProcess = ManagedProcessRecord(
    pid: 42,
    processGroupId: 42,
    processStartTimeSeconds: 1_700_000_000,
    kind: .agentTerminal,
    provider: SessionProviderKind.claude.rawValue,
    terminalKey: "terminal-session-1",
    sessionId: sessionId,
    projectPath: parentRepoPath,
    expectedExecutable: "/bin/zsh",
    registeredAt: Date(timeIntervalSince1970: 1_700_000_010),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_020)
  )

  let queue = try DatabaseQueue(path: dbPath)
  try queue.write { db in
    try createCurrentBaselineSchema(in: db)

    try SessionMetadata(
      sessionId: sessionId,
      customName: "Important session",
      isPinned: true
    ).insert(db)

    try SessionRepoMapping(
      sessionId: sessionId,
      parentRepoPath: parentRepoPath,
      worktreePath: worktreePath
    ).insert(db)

    try AIConfigRecord(
      provider: "claude",
      defaultModel: "opus",
      effortLevel: "high",
      allowedTools: "Read, Edit",
      disallowedTools: "Bash(rm *)",
      approvalPolicy: "on-request"
    ).insert(db)

    try TerminalWorkspaceRecord(
      provider: SessionProviderKind.claude.rawValue,
      sessionId: sessionId,
      backend: EmbeddedTerminalBackend.ghostty.rawValue,
      snapshotData: JSONEncoder().encode(terminalWorkspace)
    ).insert(db)

    try SessionWorkspaceStateRecord(
      provider: SessionProviderKind.claude.rawValue,
      state: workspaceState
    ).insert(db)

    try managedProcess.insert(db)

    // Mark the database as fully migrated through v7 so opening
    // SessionMetadataStore exercises only the v8 claude_hook_installations migration.
    for migrationIdentifier in SessionMetadataStore.migrationIdentifiers
      where migrationIdentifier != SessionMetadataStore.MigrationID.createClaudeHookInstallations {
      try db.execute(
        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
        arguments: [migrationIdentifier]
      )
    }
  }

  return MigrationSafetySeed(
    sessionId: sessionId,
    parentRepoPath: parentRepoPath,
    worktreePath: worktreePath,
    terminalWorkspace: terminalWorkspace,
    workspaceState: workspaceState,
    managedProcess: managedProcess
  )
}

private func createCurrentBaselineSchema(in db: Database) throws {
  try db.create(table: "session_metadata") { t in
    t.column("sessionId", .text).primaryKey()
    t.column("customName", .text)
    t.column("createdAt", .datetime).notNull()
    t.column("updatedAt", .datetime).notNull()
    t.column("isPinned", .boolean).notNull().defaults(to: false)
  }

  try db.create(table: "session_repo_mapping") { t in
    t.column("sessionId", .text).primaryKey()
    t.column("parentRepoPath", .text).notNull().indexed()
    t.column("worktreePath", .text).notNull()
    t.column("assignedAt", .datetime).notNull()
  }

  try db.create(table: "ai_config") { t in
    t.column("provider", .text).primaryKey()
    t.column("defaultModel", .text).notNull().defaults(to: "")
    t.column("effortLevel", .text).notNull().defaults(to: "")
    t.column("allowedTools", .text).notNull().defaults(to: "")
    t.column("disallowedTools", .text).notNull().defaults(to: "")
    t.column("approvalPolicy", .text).notNull().defaults(to: "")
    t.column("updatedAt", .datetime).notNull()
  }

  try db.create(table: "terminal_workspaces") { t in
    t.column("provider", .text).notNull()
    t.column("sessionId", .text).notNull()
    t.column("backend", .integer).notNull()
    t.column("snapshotData", .blob).notNull()
    t.column("updatedAt", .datetime).notNull()
    t.primaryKey(["provider", "sessionId", "backend"], onConflict: .replace)
  }

  try db.create(table: "session_workspace_state") { t in
    t.column("provider", .text).primaryKey()
    t.column("selectedRepositoryPathsData", .blob).notNull()
    t.column("monitoredSessionIdsData", .blob).notNull()
    t.column("expansionStateData", .blob).notNull()
    t.column("updatedAt", .datetime).notNull()
  }

  try db.create(table: "managed_processes") { t in
    t.column("pid", .integer).primaryKey(onConflict: .replace)
    t.column("processGroupId", .integer)
    t.column("processStartTimeSeconds", .integer)
    t.column("kind", .text).notNull()
    t.column("provider", .text)
    t.column("terminalKey", .text)
    t.column("sessionId", .text)
    t.column("projectPath", .text)
    t.column("expectedExecutable", .text)
    t.column("registeredAt", .datetime).notNull()
    t.column("updatedAt", .datetime).notNull()
  }
  try db.create(index: "idx_managed_processes_kind", on: "managed_processes", columns: ["kind"])
  try db.create(index: "idx_managed_processes_session", on: "managed_processes", columns: ["provider", "sessionId"])

  try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
}

private func temporaryMigrationSafetyDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "test_migration_safety_\(UUID().uuidString).sqlite")
    .path
}
