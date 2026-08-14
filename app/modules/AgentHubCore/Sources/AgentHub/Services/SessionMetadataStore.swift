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
public actor SessionMetadataStore: TerminalWorkspaceStoreProtocol, AgentWorkspaceStoreProtocol {

  // MARK: - Properties

  enum MigrationID {
    static let createSessionMetadata = "v1_create_session_metadata"
    static let createSessionRepoMapping = "v2_create_session_repo_mapping"
    static let createAIConfig = "v3_create_ai_config"
    static let addPinned = "v4_add_pinned"
    static let createTerminalWorkspaces = "v5_create_terminal_workspaces"
    static let createSessionWorkspaceState = "v6_create_session_workspace_state"
    static let createManagedProcesses = "v7_create_managed_processes"
    static let createClaudeHookInstallations = "v8_create_claude_hook_installations"
    static let addOwnedWorktreePaths = "v9_add_owned_worktree_paths"
    static let createSessionRelationships = "v10_create_session_relationships"
    static let createProjectSimulatorPreferences = "v11_create_project_simulator_preferences"
    static let createAgentWorkspaces = "v12_create_agent_workspaces"
    static let createPinnedSessionOrder = "v13_create_pinned_session_order"
    static let createSessionMeasurements = "v14_create_session_measurements"
    static let addMeasurementProjectPath = "v15_add_measurement_project_path"
    static let createContextProfiles = "v16_create_context_profiles"
    static let createSessionLaunchContext = "v17_create_session_launch_context"
  }

  static let migrationIdentifiers = [
    MigrationID.createSessionMetadata,
    MigrationID.createSessionRepoMapping,
    MigrationID.createAIConfig,
    MigrationID.addPinned,
    MigrationID.createTerminalWorkspaces,
    MigrationID.createSessionWorkspaceState,
    MigrationID.createManagedProcesses,
    MigrationID.createClaudeHookInstallations,
    MigrationID.addOwnedWorktreePaths,
    MigrationID.createSessionRelationships,
    MigrationID.createProjectSimulatorPreferences,
    MigrationID.createAgentWorkspaces,
    MigrationID.createPinnedSessionOrder,
    MigrationID.createSessionMeasurements,
    MigrationID.addMeasurementProjectPath,
    MigrationID.createContextProfiles,
    MigrationID.createSessionLaunchContext
  ]

  private let dbQueue: DatabaseQueue

  // MARK: - Initialization

  /// Creates a new metadata store at the default location:
  /// `AgentHubApplicationSupport.baseDirectoryURL/session_metadata.sqlite`
  /// (the real Application Support dir in the app; a temp sandbox under tests).
  public init() throws {
    let agentHubDir = AgentHubApplicationSupport.baseDirectoryURL
    try FileManager.default.createDirectory(
      at: agentHubDir,
      withIntermediateDirectories: true
    )

    let dbPath = agentHubDir.appendingPathComponent("session_metadata.sqlite")
    dbQueue = try DatabaseQueue(path: dbPath.path, configuration: Self.databaseConfiguration())

    try migrator.migrate(dbQueue)
  }

  /// Creates a store with a custom database path (for testing)
  public init(path: String) throws {
    dbQueue = try DatabaseQueue(path: path, configuration: Self.databaseConfiguration())
    try migrator.migrate(dbQueue)
  }

  /// Waits out transient cross-process lock contention instead of surfacing
  /// SQLITE_BUSY immediately — a busy read must not masquerade as empty state.
  private static func databaseConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.busyMode = .timeout(5)
    return configuration
  }

  // MARK: - Migrations

  private nonisolated var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    migrator.registerMigration(MigrationID.createSessionMetadata) { db in
      try db.create(table: "session_metadata") { t in
        t.column("sessionId", .text).primaryKey()
        t.column("customName", .text)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration(MigrationID.createSessionRepoMapping) { db in
      try db.create(table: "session_repo_mapping") { t in
        t.column("sessionId", .text).primaryKey()
        t.column("parentRepoPath", .text).notNull().indexed()
        t.column("worktreePath", .text).notNull()
        t.column("assignedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration(MigrationID.createAIConfig) { db in
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

    migrator.registerMigration(MigrationID.addPinned) { db in
      try db.alter(table: "session_metadata") { t in
        t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
      }
    }

    migrator.registerMigration(MigrationID.createTerminalWorkspaces) { db in
      try db.create(table: "terminal_workspaces") { t in
        t.column("provider", .text).notNull()
        t.column("sessionId", .text).notNull()
        t.column("backend", .integer).notNull()
        t.column("snapshotData", .blob).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(["provider", "sessionId", "backend"], onConflict: .replace)
      }
    }

    migrator.registerMigration(MigrationID.createSessionWorkspaceState) { db in
      try db.create(table: "session_workspace_state") { t in
        t.column("provider", .text).primaryKey()
        t.column("selectedRepositoryPathsData", .blob).notNull()
        t.column("monitoredSessionIdsData", .blob).notNull()
        t.column("expansionStateData", .blob).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration(MigrationID.createManagedProcesses) { db in
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
    }

    migrator.registerMigration(MigrationID.createClaudeHookInstallations) { db in
      try db.create(table: "claude_hook_installations") { t in
        t.column("projectPath", .text).primaryKey()
        t.column("installedAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration(MigrationID.addOwnedWorktreePaths) { db in
      try db.alter(table: "session_workspace_state") { t in
        t.add(column: "ownedWorktreePathsData", .blob)
      }
    }

    migrator.registerMigration(MigrationID.createSessionRelationships) { db in
      try db.create(table: "session_relationships") { t in
        t.column("sourceProvider", .text).notNull()
        t.column("sourceSessionId", .text).notNull()
        t.column("targetProvider", .text).notNull()
        t.column("targetSessionId", .text).notNull()
        t.column("kind", .text).notNull()
        t.column("origin", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(
          ["sourceProvider", "sourceSessionId", "targetProvider", "targetSessionId", "kind"],
          onConflict: .replace
        )
      }
      try db.create(
        index: "idx_session_relationships_source",
        on: "session_relationships",
        columns: ["sourceProvider", "sourceSessionId", "kind"]
      )
      try db.create(
        index: "idx_session_relationships_target",
        on: "session_relationships",
        columns: ["targetProvider", "targetSessionId", "kind"]
      )
    }

    migrator.registerMigration(MigrationID.createProjectSimulatorPreferences) { db in
      try db.create(table: "project_simulator_preferences") { t in
        t.column("projectPath", .text).primaryKey(onConflict: .replace)
        t.column("deviceIdentifier", .text).notNull()
        t.column("kind", .text).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration(MigrationID.createAgentWorkspaces) { db in
      try db.create(table: "agent_workspaces") { t in
        t.column("id", .text).primaryKey()
        t.column("projectPath", .text).notNull().indexed()
        t.column("customName", .text)
        t.column("backend", .integer).notNull()
        t.column("snapshotData", .blob).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
      }

      try db.create(table: "workspace_session_links") { t in
        t.column("workspaceId", .text)
          .notNull()
          .references("agent_workspaces", onDelete: .cascade)
        t.column("provider", .text).notNull()
        t.column("sessionId", .text).notNull()
        t.column("origin", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.primaryKey(["workspaceId", "provider", "sessionId"], onConflict: .replace)
        t.uniqueKey(["provider", "sessionId"])
      }
      try db.create(
        index: "idx_workspace_session_links_workspace",
        on: "workspace_session_links",
        columns: ["workspaceId"]
      )
    }

    // Manual drag order for the sidebar's pinned section. Keyed by the
    // provider-scoped sidebar item id ("claude-<sessionId>") rather than the
    // bare session id, because the pinned list is a union across providers.
    migrator.registerMigration(MigrationID.createPinnedSessionOrder) { db in
      try db.create(table: "pinned_session_order") { t in
        t.column("itemId", .text).primaryKey()
        t.column("sortIndex", .integer).notNull()
        t.column("updatedAt", .datetime).notNull()
      }
    }

    // Measurements an agent filed into a session's Measurements panel. Keyed by the
    // measurement id the CLI generated so a queue entry drained twice (app restart
    // mid-drain) replaces rather than duplicates.
    migrator.registerMigration(MigrationID.createSessionMeasurements) { db in
      try db.create(table: "session_measurements") { t in
        t.column("id", .text).primaryKey(onConflict: .replace)
        t.column("sessionId", .text).notNull().indexed()
        t.column("provider", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("payloadVersion", .integer).notNull()
        t.column("payloadData", .blob).notNull()
      }
    }

    // Measurements are scoped to a project, not a session: a measurement about a
    // repo or a database outlives the conversation that produced it, and
    // keying it to a session hides last month's number from this month's work.
    // Existing rows are backfilled from the payload they already carry, so no
    // measurement is lost.
    migrator.registerMigration(MigrationID.addMeasurementProjectPath) { db in
      try db.alter(table: "session_measurements") { t in
        t.add(column: "projectPath", .text).notNull().defaults(to: "")
      }

      let rows = try Row.fetchAll(db, sql: "SELECT id, payloadData FROM session_measurements")
      for row in rows {
        guard let payload: Data = row["payloadData"],
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sourceProjectPath = object["sourceProjectPath"] as? String,
              !sourceProjectPath.isEmpty
        else {
          continue
        }
        try db.execute(
          sql: "UPDATE session_measurements SET projectPath = ? WHERE id = ?",
          arguments: [MeasurementProjectScope.normalized(sourceProjectPath), row["id"] as String?]
        )
      }

      try db.create(
        index: "idx_session_measurements_project",
        on: "session_measurements",
        columns: ["projectPath"]
      )
    }

    // Named context profiles for curated launch context. projectPath "" is the
    // personal (user-level) scope, matching the v15 sentinel convention. The
    // partial unique index makes "one default per project" a database
    // guarantee rather than app discipline.
    //
    // The drop guard clears a `context_profiles` table left by an abandoned
    // experiment on a development branch (its `v11_create_context_profiles`
    // was never in this lineage, so no migration here ever created that
    // table). On databases from this lineage the drop is a no-op.
    migrator.registerMigration(MigrationID.createContextProfiles) { db in
      try db.execute(sql: "DROP TABLE IF EXISTS context_profiles")
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
    }

    // Curated launch context per session, so resume launches can re-pass the
    // out-of-band context (system-prompt channel) the session started with —
    // that text never enters conversation history, unlike the old
    // first-message injection.
    migrator.registerMigration(MigrationID.createSessionLaunchContext) { db in
      try db.create(table: "session_launch_context") { t in
        t.column("sessionId", .text).primaryKey()
        t.column("provider", .text).notNull()
        t.column("projectPath", .text).notNull()
        t.column("contextText", .text).notNull()
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

  // MARK: - Pinned Section Manual Order

  /// Replaces the pinned section's manual order with `orderedItemIds`.
  ///
  /// Positions are rewritten as a dense `0..<count` range in one transaction so
  /// a partial write can never leave two rows fighting for the same slot. Rows
  /// for items not in the list are left alone — unpinning a session keeps its
  /// slot, so re-pinning it restores the position the user chose.
  public func setPinnedSessionOrder(_ orderedItemIds: [String]) throws {
    try dbQueue.write { db in
      let now = Date()
      for (index, itemId) in orderedItemIds.enumerated() {
        try PinnedSessionOrderRecord(
          itemId: itemId,
          sortIndex: index,
          updatedAt: now
        ).save(db)
      }
    }
  }

  /// Gets the manual pinned order as `itemId -> sortIndex`
  public func getPinnedSessionOrder() throws -> [String: Int] {
    try dbQueue.read { db in
      try Self.readPinnedSessionOrder(db)
    }
  }

  /// Synchronous read for the manual pinned order — safe to call from
  /// non-async contexts. Mirrors `getPinnedSessionIdsSync()` so the sidebar can
  /// render the user's order on the first frame instead of flashing the
  /// activity sort and then resorting.
  public nonisolated func getPinnedSessionOrderSync() -> [String: Int] {
    (try? dbQueue.read { db in
      try Self.readPinnedSessionOrder(db)
    }) ?? [:]
  }

  /// Removes any stored pinned position for a sidebar item
  public func deletePinnedSessionOrder(forItemIds itemIds: [String]) throws {
    guard !itemIds.isEmpty else { return }
    _ = try dbQueue.write { db in
      try PinnedSessionOrderRecord
        .filter(itemIds.contains(Column("itemId")))
        .deleteAll(db)
    }
  }

  private static func readPinnedSessionOrder(_ db: Database) throws -> [String: Int] {
    let records = try PinnedSessionOrderRecord.fetchAll(db)
    return Dictionary(
      records.map { ($0.itemId, $0.sortIndex) },
      uniquingKeysWith: { first, _ in first }
    )
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
      _ = try TerminalWorkspaceRecord
        .filter(Column("sessionId") == sessionId)
        .deleteAll(db)
      _ = try SessionMetadata.deleteOne(db, key: sessionId)
      // Pinned positions are keyed by provider-scoped item id, so clear the
      // slot this session could hold under either provider.
      let itemIds = SessionProviderKind.allCases.map {
        SidebarSessionItemID.monitored(provider: $0, sessionId: sessionId)
      }
      _ = try PinnedSessionOrderRecord
        .filter(itemIds.contains(Column("itemId")))
        .deleteAll(db)
    }
  }

  /// Clears all metadata (for testing/reset)
  public func clearAll() throws {
    try dbQueue.write { db in
      _ = try AgentWorkspaceSessionLink.deleteAll(db)
      _ = try AgentWorkspaceRecord.deleteAll(db)
      _ = try TerminalWorkspaceRecord.deleteAll(db)
      _ = try SessionWorkspaceStateRecord.deleteAll(db)
      _ = try ClaudeHookInstallationRecord.deleteAll(db)
      _ = try ManagedProcessRecord.deleteAll(db)
      _ = try SessionRelationshipRecord.deleteAll(db)
      _ = try ProjectSimulatorPreference.deleteAll(db)
      _ = try AIConfigRecord.deleteAll(db)
      _ = try SessionRepoMapping.deleteAll(db)
      _ = try PinnedSessionOrderRecord.deleteAll(db)
      _ = try SessionMeasurementRecord.deleteAll(db)
      _ = try SessionMetadata.deleteAll(db)
    }
  }

  // MARK: - Workspace State

  /// Throwing read that distinguishes "no saved row" (returns an empty state)
  /// from a failed read (throws). Callers deciding whether it is safe to
  /// *write* workspace state must use this — treating a failed read as empty
  /// and saving over it is how persisted repositories/sessions get lost.
  public nonisolated func readWorkspaceState(for provider: SessionProviderKind) throws -> SessionWorkspaceState {
    try dbQueue.read { db in
      try SessionWorkspaceStateRecord
        .filter(Column("provider") == provider.rawValue)
        .fetchOne(db)?
        .decodedState()
    } ?? SessionWorkspaceState()
  }

  /// Display-only convenience: errors collapse to an empty state. Never use
  /// this to decide whether saving workspace state is safe.
  public nonisolated func getWorkspaceStateSync(for provider: SessionProviderKind) -> SessionWorkspaceState {
    (try? readWorkspaceState(for: provider)) ?? SessionWorkspaceState()
  }

  public func saveWorkspaceState(_ state: SessionWorkspaceState, for provider: SessionProviderKind) async throws {
    let record = try SessionWorkspaceStateRecord(provider: provider.rawValue, state: state)
    try await dbQueue.write { db in
      try record.save(db)
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

  // MARK: - Terminal Workspaces

  public nonisolated func loadTerminalWorkspace(
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) -> TerminalWorkspaceSnapshot? {
    try? dbQueue.read { db in
      guard let record = try TerminalWorkspaceRecord
        .filter(Column("provider") == provider.rawValue)
        .filter(Column("sessionId") == sessionId)
        .filter(Column("backend") == backend.rawValue)
        .fetchOne(db)
      else {
        return nil
      }

      return try JSONDecoder().decode(TerminalWorkspaceSnapshot.self, from: record.snapshotData)
    }
  }

  public func saveTerminalWorkspace(
    _ snapshot: TerminalWorkspaceSnapshot,
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) async throws {
    let data = try JSONEncoder().encode(snapshot)
    let record = TerminalWorkspaceRecord(
      provider: provider.rawValue,
      sessionId: sessionId,
      backend: backend.rawValue,
      snapshotData: data
    )

    try await dbQueue.write { db in
      try record.save(db)
    }
  }

  public func deleteTerminalWorkspace(
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) async throws {
    try await dbQueue.write { db in
      _ = try TerminalWorkspaceRecord
        .filter(Column("provider") == provider.rawValue)
        .filter(Column("sessionId") == sessionId)
        .filter(Column("backend") == backend.rawValue)
        .deleteAll(db)
    }
  }

  // MARK: - Agent Workspaces

  public func loadAgentWorkspaces() async throws -> [AgentWorkspaceRecord] {
    try await dbQueue.read { db in
      try AgentWorkspaceRecord
        .order(Column("createdAt").desc)
        .fetchAll(db)
    }
  }

  public func loadAgentWorkspaceSessionLinks() async throws -> [AgentWorkspaceSessionLink] {
    try await dbQueue.read { db in
      try AgentWorkspaceSessionLink
        .order(Column("createdAt"))
        .fetchAll(db)
    }
  }

  public func saveAgentWorkspace(
    _ workspace: AgentWorkspaceRecord,
    links: [AgentWorkspaceSessionLink]
  ) async throws {
    try await dbQueue.write { db in
      try workspace.save(db)
      _ = try AgentWorkspaceSessionLink
        .filter(Column("workspaceId") == workspace.id)
        .deleteAll(db)
      for link in links {
        try link.save(db)
      }
    }
  }

  public func deleteAgentWorkspace(id: String) async throws {
    try await dbQueue.write { db in
      _ = try AgentWorkspaceSessionLink
        .filter(Column("workspaceId") == id)
        .deleteAll(db)
      _ = try AgentWorkspaceRecord.deleteOne(db, key: id)
    }
  }
}

extension SessionMetadataStore: ManagedProcessStoreProtocol {
  public func saveManagedProcess(_ record: ManagedProcessRecord) async throws {
    try await dbQueue.write { db in
      try record.save(db)
    }
  }

  public func deleteManagedProcess(pid: Int32) async throws {
    try await dbQueue.write { db in
      _ = try ManagedProcessRecord.deleteOne(db, key: pid)
    }
  }

  public func deleteManagedProcesses(pids: [Int32]) async throws {
    guard !pids.isEmpty else { return }
    try await dbQueue.write { db in
      _ = try ManagedProcessRecord
        .filter(pids.contains(Column("pid")))
        .deleteAll(db)
    }
  }

  public func getManagedProcesses() async throws -> [ManagedProcessRecord] {
    try await dbQueue.read { db in
      try ManagedProcessRecord.fetchAll(db)
    }
  }
}

extension SessionMetadataStore: SessionRelationshipStoreProtocol {
  public func saveSessionRelationship(_ relationship: SessionRelationshipRecord) async throws {
    var updatedRecord = relationship
    let now = Date()
    updatedRecord.updatedAt = now

    try await dbQueue.write { db in
      var record = updatedRecord
      if let existing = try SessionRelationshipRecord
        .filter(Column("sourceProvider") == record.sourceProvider)
        .filter(Column("sourceSessionId") == record.sourceSessionId)
        .filter(Column("targetProvider") == record.targetProvider)
        .filter(Column("targetSessionId") == record.targetSessionId)
        .filter(Column("kind") == record.kind)
        .fetchOne(db) {
        record.createdAt = existing.createdAt
      }
      try record.save(db)
    }
  }

  public func sessionRelationships(
    from sourceProvider: SessionProviderKind,
    sessionId: String,
    kind: SessionRelationshipKind?
  ) async throws -> [SessionRelationshipRecord] {
    try await dbQueue.read { db in
      var request = SessionRelationshipRecord
        .filter(Column("sourceProvider") == sourceProvider.rawValue)
        .filter(Column("sourceSessionId") == sessionId)
      if let kind {
        request = request.filter(Column("kind") == kind.rawValue)
      }
      return try request
        .order(Column("createdAt"))
        .fetchAll(db)
    }
  }

  public func sessionRelationships(
    to targetProvider: SessionProviderKind,
    sessionId: String,
    kind: SessionRelationshipKind?
  ) async throws -> [SessionRelationshipRecord] {
    try await dbQueue.read { db in
      var request = SessionRelationshipRecord
        .filter(Column("targetProvider") == targetProvider.rawValue)
        .filter(Column("targetSessionId") == sessionId)
      if let kind {
        request = request.filter(Column("kind") == kind.rawValue)
      }
      return try request
        .order(Column("createdAt"))
        .fetchAll(db)
    }
  }

  public func deleteSessionRelationship(
    sourceProvider: SessionProviderKind,
    sourceSessionId: String,
    targetProvider: SessionProviderKind,
    targetSessionId: String,
    kind: SessionRelationshipKind
  ) async throws {
    try await dbQueue.write { db in
      _ = try SessionRelationshipRecord
        .filter(Column("sourceProvider") == sourceProvider.rawValue)
        .filter(Column("sourceSessionId") == sourceSessionId)
        .filter(Column("targetProvider") == targetProvider.rawValue)
        .filter(Column("targetSessionId") == targetSessionId)
        .filter(Column("kind") == kind.rawValue)
        .deleteAll(db)
    }
  }

  // MARK: - Project Simulator Preferences

  /// Gets all persisted run-destination preferences, keyed one row per project path
  public func getProjectSimulatorPreferences() throws -> [ProjectSimulatorPreference] {
    try dbQueue.read { db in
      try ProjectSimulatorPreference.fetchAll(db)
    }
  }

  /// Synchronous read for launch configuration, safe to call from non-async contexts.
  /// Returns an empty list if the store cannot be read.
  public nonisolated func getProjectSimulatorPreferencesSync() -> [ProjectSimulatorPreference] {
    (try? dbQueue.read { db in
      try ProjectSimulatorPreference.fetchAll(db)
    }) ?? []
  }

  /// Saves the run destination for a project path (replaces any prior row)
  public func setProjectSimulatorPreference(_ preference: ProjectSimulatorPreference) throws {
    try dbQueue.write { db in
      try preference.save(db)
    }
  }

  /// Deletes the run-destination preference for a project path
  public func deleteProjectSimulatorPreference(projectPath: String) throws {
    try dbQueue.write { db in
      _ = try ProjectSimulatorPreference.deleteOne(db, key: projectPath)
    }
  }
}

// MARK: - Session Measurement

extension SessionMetadataStore {
  /// Stores one measurement card. `save` (upsert) rather than `insert` so a queue
  /// entry drained twice is idempotent.
  public func saveMeasurement(_ record: SessionMeasurementRecord) throws {
    try dbQueue.write { db in
      try record.save(db)
    }
  }

  /// Measurements for a project, newest first — the order the panel renders.
  ///
  /// Spans every session and both providers: Claude and Codex sessions in the
  /// same repo contribute to one shared set.
  public func getMeasurements(forProjectPath projectPath: String) throws -> [SessionMeasurementRecord] {
    let key = MeasurementProjectScope.normalized(projectPath)
    return try dbQueue.read { db in
      try SessionMeasurementRecord
        .filter(Column("projectPath") == key)
        .order(Column("createdAt").desc, Column("id").desc)
        .fetchAll(db)
    }
  }

  /// Every stored measurement, for the Settings management view.
  ///
  /// Loads whole payloads rather than a summary query because the counts here
  /// are small (tens per project) and the view needs each card's title and last
  /// run — deriving those from a `GROUP BY` would mean a second round trip per
  /// project anyway.
  public func getAllMeasurements() throws -> [SessionMeasurementRecord] {
    try dbQueue.read { db in
      try SessionMeasurementRecord
        .order(Column("createdAt").desc, Column("id").desc)
        .fetchAll(db)
    }
  }

  /// Projects that have at least one card, so the card button can gate without
  /// loading every payload.
  public func getProjectPathsWithMeasurements() throws -> Set<String> {
    try dbQueue.read { db in
      let paths = try String.fetchAll(
        db,
        sql: "SELECT DISTINCT projectPath FROM \(SessionMeasurementRecord.databaseTableName)"
      )
      return Set(paths.filter { !$0.isEmpty })
    }
  }

  public func deleteMeasurement(id: String) throws {
    _ = try dbQueue.write { db in
      try SessionMeasurementRecord.deleteOne(db, key: id)
    }
  }

  public func deleteAllMeasurements(forProjectPath projectPath: String) throws {
    let key = MeasurementProjectScope.normalized(projectPath)
    _ = try dbQueue.write { db in
      try SessionMeasurementRecord
        .filter(Column("projectPath") == key)
        .deleteAll(db)
    }
  }

  /// Drops rows that could never be shown again — measurements whose project was
  /// never resolved. Without this they accumulate invisibly forever.
  @discardableResult
  public func deleteUnscopedMeasurements() throws -> Int {
    try dbQueue.write { db in
      try SessionMeasurementRecord
        .filter(Column("projectPath") == "")
        .deleteAll(db)
    }
  }
}

// MARK: - Context Profiles

extension SessionMetadataStore {
  /// Stores one context profile. `save` (upsert) so re-saving an edited profile
  /// replaces rather than duplicates.
  public func saveContextProfile(_ record: ContextProfileRecord) throws {
    try dbQueue.write { db in
      try record.save(db)
    }
  }

  /// Project-scoped profiles for a project, name-ordered.
  public func getContextProfiles(forProjectPath projectPath: String) throws -> [ContextProfileRecord] {
    let key = MeasurementProjectScope.normalized(projectPath)
    return try dbQueue.read { db in
      try ContextProfileRecord
        .filter(Column("projectPath") == key)
        .order(Column("name").collating(.localizedCaseInsensitiveCompare))
        .fetchAll(db)
    }
  }

  /// Personal (user-level) profiles, name-ordered.
  public func getPersonalContextProfiles() throws -> [ContextProfileRecord] {
    try dbQueue.read { db in
      try ContextProfileRecord
        .filter(Column("projectPath") == "")
        .order(Column("name").collating(.localizedCaseInsensitiveCompare))
        .fetchAll(db)
    }
  }

  /// Projects that have at least one profile — used to republish the JSON index
  /// after a personal-scope mutation without loading every payload.
  public func getProjectPathsWithContextProfiles() throws -> Set<String> {
    try dbQueue.read { db in
      let paths = try String.fetchAll(
        db,
        sql: "SELECT DISTINCT projectPath FROM \(ContextProfileRecord.databaseTableName)"
      )
      return Set(paths.filter { !$0.isEmpty })
    }
  }

  public func deleteContextProfile(id: String) throws {
    _ = try dbQueue.write { db in
      try ContextProfileRecord.deleteOne(db, key: id)
    }
  }

  /// Marks `id` as the project's default profile (or clears the default when
  /// `id` is nil). One transaction: the old default is cleared before the new
  /// one is set, so the partial unique index turns any race into a constraint
  /// error instead of silent double-defaults. Personal profiles cannot be a
  /// project default.
  public func setDefaultContextProfile(id: String?, forProjectPath projectPath: String) throws {
    let key = MeasurementProjectScope.normalized(projectPath)
    try dbQueue.write { db in
      try db.execute(
        sql: "UPDATE \(ContextProfileRecord.databaseTableName) SET isDefault = 0 WHERE projectPath = ?",
        arguments: [key]
      )
      guard let id else { return }
      guard let record = try ContextProfileRecord.fetchOne(db, key: id),
        record.projectPath == key,
        record.scope == ContextProfileScope.project.rawValue
      else {
        throw DatabaseError(
          resultCode: .SQLITE_CONSTRAINT,
          message: "Default context profile must be a project-scoped profile of the same project."
        )
      }
      try db.execute(
        sql: "UPDATE \(ContextProfileRecord.databaseTableName) SET isDefault = 1 WHERE id = ?",
        arguments: [id]
      )
    }
  }

  /// Synchronous read for launch-time chip gating, safe from non-async contexts.
  public nonisolated func getDefaultContextProfileSync(forProjectPath projectPath: String) -> ContextProfileRecord? {
    let key = MeasurementProjectScope.normalized(projectPath)
    return try? dbQueue.read { db in
      try ContextProfileRecord
        .filter(Column("projectPath") == key)
        .filter(Column("isDefault") == true)
        .fetchOne(db)
    }
  }

  /// Synchronous project-scoped profile list. Returns empty if unreadable.
  public nonisolated func getContextProfilesSync(forProjectPath projectPath: String) -> [ContextProfileRecord] {
    let key = MeasurementProjectScope.normalized(projectPath)
    return (try? dbQueue.read { db in
      try ContextProfileRecord
        .filter(Column("projectPath") == key)
        .order(Column("name").collating(.localizedCaseInsensitiveCompare))
        .fetchAll(db)
    }) ?? []
  }
}

// MARK: - Session Launch Context

extension SessionMetadataStore {
  /// Rows older than this are pruned on save: launch context is only re-read
  /// when a session is resumed, and a month-old session losing its background
  /// context is preferable to unbounded growth of up-to-48 KB rows.
  public static let sessionLaunchContextMaxAge: TimeInterval = 30 * 24 * 60 * 60

  /// Records the curated context a session was launched with (upsert), pruning
  /// stale rows in the same transaction.
  public func saveSessionLaunchContext(_ record: SessionLaunchContextRecord) throws {
    try dbQueue.write { db in
      let cutoff = Date().addingTimeInterval(-Self.sessionLaunchContextMaxAge)
      try SessionLaunchContextRecord
        .filter(Column("updatedAt") < cutoff)
        .deleteAll(db)
      var record = record
      record.updatedAt = Date()
      try record.save(db)
    }
  }

  /// Synchronous read for command-line assembly at resume time, safe from
  /// non-async contexts (mirrors `getAIConfigSync`).
  public nonisolated func getSessionLaunchContextTextSync(for sessionId: String) -> String? {
    try? dbQueue.read { db in
      try SessionLaunchContextRecord
        .fetchOne(db, key: sessionId)?
        .contextText
    }
  }
}

extension SessionMetadataStore: ClaudeHookInstallStateStoreProtocol {
  public func loadClaudeHookInstalledPaths() async throws -> Set<String> {
    try await dbQueue.read { db in
      let records = try ClaudeHookInstallationRecord.fetchAll(db)
      return Set(records.map(\.projectPath))
    }
  }

  public func replaceClaudeHookInstalledPaths(_ paths: Set<String>) async throws {
    try await dbQueue.write { db in
      let existingRecords = try ClaudeHookInstallationRecord.fetchAll(db)
      let existingByPath = Dictionary(uniqueKeysWithValues: existingRecords.map { ($0.projectPath, $0) })
      let pathsToDelete = Array(Set(existingByPath.keys).subtracting(paths))
      let now = Date.now

      if !pathsToDelete.isEmpty {
        _ = try ClaudeHookInstallationRecord
          .filter(pathsToDelete.contains(Column("projectPath")))
          .deleteAll(db)
      }

      for path in paths.sorted() {
        var record = existingByPath[path] ?? ClaudeHookInstallationRecord(projectPath: path, installedAt: now)
        record.updatedAt = now
        try record.save(db)
      }
    }
  }
}
