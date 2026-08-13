import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Context profile store")
struct ContextProfileStoreTests {

  @Test("A profile round-trips through SQLite with its selection intact")
  func profileRoundTrips() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    let profile = makeProfile(name: "Voice work")

    try await store.saveContextProfile(ContextProfileRecord(profile: profile))

    let stored = try await store.getContextProfiles(forProjectPath: "/tmp/project")
    #expect(stored.count == 1)
    #expect(try stored.first?.decodedProfile() == profile)
  }

  @Test("Selections saved before externalPaths existed still decode")
  func legacySelectionPayloadDecodes() throws {
    let legacyJSON = Data(#"{"files":[{"relativePath":"a.swift"}],"instructions":"hi"}"#.utf8)
    let decoded = try JSONDecoder().decode(ContextSelection.self, from: legacyJSON)

    #expect(decoded.files.map(\.relativePath) == ["a.swift"])
    #expect(decoded.externalPaths.isEmpty)
    #expect(decoded.textSnippets.isEmpty)
    #expect(decoded.instructions == "hi")
  }

  @Test("Text snippets survive the profile round trip")
  func textSnippetsRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    var profile = makeProfile(id: "snip", name: "With snippet")
    profile.selection.textSnippets = [
      ContextTextSnippet(id: "s1", title: "API notes", content: "POST /v1/things returns 201")
    ]

    try await store.saveContextProfile(ContextProfileRecord(profile: profile))

    let decoded = try #require(
      try await store.getContextProfiles(forProjectPath: "/tmp/project").first?.decodedProfile())
    #expect(decoded.selection.textSnippets.count == 1)
    #expect(decoded.selection.textSnippets.first?.title == "API notes")
    #expect(decoded.selection.textSnippets.first?.content == "POST /v1/things returns 201")
  }

  @Test("External paths survive the profile round trip")
  func externalPathsRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    var profile = makeProfile(id: "ext", name: "With externals")
    profile.selection.externalPaths = ["/Users/me/books/swift-book.md"]

    try await store.saveContextProfile(ContextProfileRecord(profile: profile))

    let decoded = try #require(
      try await store.getContextProfiles(forProjectPath: "/tmp/project").first?.decodedProfile())
    #expect(decoded.selection.externalPaths == ["/Users/me/books/swift-book.md"])
  }

  @Test("Profiles list name-ordered, case-insensitively")
  func profilesListNameOrdered() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    for name in ["zeta", "Alpha", "beta"] {
      try await store.saveContextProfile(
        ContextProfileRecord(profile: makeProfile(id: name, name: name)))
    }

    #expect(
      try await store.getContextProfiles(forProjectPath: "/tmp/project").map(\.name)
        == ["Alpha", "beta", "zeta"])
  }

  @Test("Personal and project scopes stay separate")
  func scopesStaySeparate() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    try await store.saveContextProfile(
      ContextProfileRecord(profile: makeProfile(id: "proj", name: "Project profile")))
    try await store.saveContextProfile(
      ContextProfileRecord(profile: makePersonalProfile(id: "pers", name: "Personal profile")))

    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/project").map(\.id) == ["proj"])
    #expect(try await store.getPersonalContextProfiles().map(\.id) == ["pers"])
    #expect(try await store.getProjectPathsWithContextProfiles() == ["/tmp/project"])
  }

  @Test("Project lookup normalizes the path")
  func projectLookupNormalizesPath() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile()))

    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/project/").count == 1)
    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/nested/../project").count == 1)
  }

  @Test("Setting a default swaps the previous one in a single transaction")
  func setDefaultSwaps() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "first", name: "First")))
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "second", name: "Second")))

    try await store.setDefaultContextProfile(id: "first", forProjectPath: "/tmp/project")
    try await store.setDefaultContextProfile(id: "second", forProjectPath: "/tmp/project")

    let profiles = try await store.getContextProfiles(forProjectPath: "/tmp/project")
    #expect(profiles.first { $0.id == "second" }?.isDefault == true)
    #expect(profiles.first { $0.id == "first" }?.isDefault == false)

    try await store.setDefaultContextProfile(id: nil, forProjectPath: "/tmp/project")
    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/project").allSatisfy { !$0.isDefault })
  }

  @Test("A personal profile cannot become a project default")
  func personalProfileRejectedAsDefault() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    try await store.saveContextProfile(
      ContextProfileRecord(profile: makePersonalProfile(id: "pers", name: "Personal")))

    await #expect(throws: (any Error).self) {
      try await store.setDefaultContextProfile(id: "pers", forProjectPath: "/tmp/project")
    }
  }

  @Test("An unknown id cannot become a default, and the old default is not lost silently")
  func unknownIdRejectedAsDefault() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "real", name: "Real")))
    try await store.setDefaultContextProfile(id: "real", forProjectPath: "/tmp/project")

    await #expect(throws: (any Error).self) {
      try await store.setDefaultContextProfile(id: "ghost", forProjectPath: "/tmp/project")
    }
    // The failed transaction rolled back, so the previous default survives.
    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/project").first?.isDefault == true)
  }

  /// The partial unique index is the last line of defense: a record slipping in
  /// with isDefault already set while another default exists must fail loudly.
  @Test("The database rejects a second default row for one project")
  func databaseRejectsSecondDefault() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "a", name: "A")))
    try await store.setDefaultContextProfile(id: "a", forProjectPath: "/tmp/project")

    var sneaky = makeProfile(id: "b", name: "B")
    sneaky.isDefault = true
    await #expect(throws: (any Error).self) {
      try await store.saveContextProfile(ContextProfileRecord(profile: sneaky))
    }
  }

  @Test("Sync readers return the default profile and the project list")
  func syncReaders() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "a", name: "A")))
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "b", name: "B")))
    try await store.setDefaultContextProfile(id: "b", forProjectPath: "/tmp/project")

    #expect(store.getDefaultContextProfileSync(forProjectPath: "/tmp/project")?.id == "b")
    #expect(store.getContextProfilesSync(forProjectPath: "/tmp/project").map(\.id) == ["a", "b"])
    #expect(store.getDefaultContextProfileSync(forProjectPath: "/tmp/other") == nil)
  }

  @Test("Deleting a profile leaves the rest")
  func deleteLeavesRest() async throws {
    let store = try SessionMetadataStore(path: temporaryContextDatabasePath())
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "a", name: "A")))
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "b", name: "B")))

    try await store.deleteContextProfile(id: "a")

    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/project").map(\.id) == ["b"])
  }

  @Test("Profiles survive reopening the database")
  func profilesSurviveReopen() async throws {
    let path = temporaryContextDatabasePath()
    let store = try SessionMetadataStore(path: path)
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "kept", name: "Kept")))

    let reopened = try SessionMetadataStore(path: path)
    #expect(try await reopened.getContextProfiles(forProjectPath: "/tmp/project").map(\.id) == ["kept"])
  }

  /// Replicates a database that ran builds from a divergent development
  /// branch: its ledger holds foreign migration identifiers and an abandoned
  /// `context_profiles` table with a different schema (and zero rows). v16
  /// must clear that leftover and succeed instead of failing on CREATE TABLE
  /// — the failure mode that renders the whole app store-less.
  @Test("v16 migration recovers from a divergent branch's leftover context_profiles table")
  func v16MigrationRecoversFromForeignLeftoverTable() async throws {
    let path = temporaryContextDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)

    try await dbQueue.write { db in
      try seedMigrationBaseline(
        before: SessionMetadataStore.MigrationID.createContextProfiles,
        in: db
      )
      try seedLegacyContextBaselineData(in: db)

      // Foreign identifiers applied by another branch's builds.
      for foreign in ["v11_create_context_profiles", "v14_create_session_findings"] {
        try db.execute(
          sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [foreign])
      }
      // The abandoned experiment's schema — incompatible with v16's.
      try db.execute(sql: """
        CREATE TABLE context_profiles (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, projectPath TEXT NOT NULL,
          schemaVersion INTEGER NOT NULL, selectionData BLOB NOT NULL,
          createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL)
        """)
      try db.execute(
        sql: "CREATE INDEX context_profiles_on_projectPath ON context_profiles(projectPath)")
      // The other branch's feature table must survive untouched.
      try db.execute(sql: "CREATE TABLE session_findings (id TEXT PRIMARY KEY, payload TEXT)")
      try db.execute(sql: "INSERT INTO session_findings (id, payload) VALUES ('f1', 'keep-me')")
    }

    let store = try SessionMetadataStore(path: path)

    // Migration succeeded, existing data is intact, and the new table works.
    #expect(try await store.getCustomName(for: "legacy-session") == "legacy-name")
    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project").map(\.id) == ["legacy-measurement"])
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "post", name: "Post")))
    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/project").map(\.id) == ["post"])

    let findings = try await dbQueue.read { db in
      try String.fetchAll(db, sql: "SELECT payload FROM session_findings")
    }
    #expect(findings == ["keep-me"])
  }

  @Test("v16 migration preserves existing metadata")
  func v16MigrationPreservesExistingMetadata() async throws {
    let path = temporaryContextDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)

    try await dbQueue.write { db in
      try seedMigrationBaseline(
        before: SessionMetadataStore.MigrationID.createContextProfiles,
        in: db
      )
      try seedLegacyContextBaselineData(in: db)
    }

    let store = try SessionMetadataStore(path: path)

    #expect(try await store.getCustomName(for: "legacy-session") == "legacy-name")
    #expect(try await store.getPinnedSessionIds() == ["legacy-session"])
    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project").map(\.id) == ["legacy-measurement"])
    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/project").isEmpty)

    // The new table is usable immediately after migrating.
    try await store.saveContextProfile(ContextProfileRecord(profile: makeProfile(id: "post", name: "Post")))
    #expect(try await store.getContextProfiles(forProjectPath: "/tmp/project").map(\.id) == ["post"])
  }
}

// MARK: - Helpers

func makeProfile(
  id: String = "profile-1",
  name: String = "Profile",
  projectPath: String = "/tmp/project",
  isDefault: Bool = false
) -> ContextProfile {
  ContextProfile(
    id: id,
    name: name,
    scope: .project,
    projectPath: projectPath,
    selection: ContextSelection(
      files: [
        ContextFileSelection(relativePath: "Sources/App/Main.swift"),
        ContextFileSelection(relativePath: "CLAUDE.md"),
      ],
      instructions: "Focus on the launch flow."
    ),
    isDefault: isDefault,
    createdAt: Date(timeIntervalSince1970: 1_000),
    updatedAt: Date(timeIntervalSince1970: 2_000)
  )
}

func makePersonalProfile(id: String = "personal-1", name: String = "Personal") -> ContextProfile {
  ContextProfile(
    id: id,
    name: name,
    scope: .personal,
    projectPath: "",
    selection: ContextSelection(
      files: [ContextFileSelection(relativePath: "README.md")],
      instructions: "Read the README first."
    ),
    createdAt: Date(timeIntervalSince1970: 1_000),
    updatedAt: Date(timeIntervalSince1970: 2_000)
  )
}

private func seedLegacyContextBaselineData(in db: Database) throws {
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
      true,
    ]
  )

  // The v15 shape of session_measurements: projectPath column already present.
  try db.create(table: "session_measurements") { t in
    t.column("id", .text).primaryKey(onConflict: .replace)
    t.column("sessionId", .text).notNull().indexed()
    t.column("provider", .text).notNull()
    t.column("createdAt", .datetime).notNull()
    t.column("payloadVersion", .integer).notNull()
    t.column("payloadData", .blob).notNull()
    t.column("projectPath", .text).notNull().defaults(to: "")
  }
  try db.create(
    index: "idx_session_measurements_project",
    on: "session_measurements",
    columns: ["projectPath"]
  )
  try db.execute(
    sql: """
    INSERT INTO session_measurements (id, sessionId, provider, createdAt, payloadVersion, payloadData, projectPath)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """,
    arguments: [
      "legacy-measurement",
      "legacy-session",
      "claude",
      Date(timeIntervalSince1970: 1_000),
      1,
      Data("{}".utf8),
      "/tmp/project",
    ]
  )
}

private func temporaryContextDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "context_profiles_\(UUID().uuidString).sqlite")
    .path
}
