import AgentHubCLIKit
import Foundation
import GRDB
import Testing

@testable import AgentHubCore

@Suite("Session measurements store")
struct SessionMeasurementStoreTests {
  @Test("A measurement round-trips through SQLite with its chart intact")
  func measurementRoundTrips() async throws {
    let store = try SessionMetadataStore(path: temporaryMeasurementDatabasePath())
    let measurement = makeMeasurement(id: "measurement-1")

    try await store.saveMeasurement(
      SessionMeasurementRecord(measurement: measurement, projectPath: "/tmp/project", sessionId: "session-1")
    )

    let stored = try await store.getMeasurements(forProjectPath: "/tmp/project")
    #expect(stored.count == 1)
    #expect(try stored.first?.decodedMeasurement() == measurement)
  }

  @Test("Measurements read back newest first")
  func measurementsReadBackNewestFirst() async throws {
    let store = try SessionMetadataStore(path: temporaryMeasurementDatabasePath())

    for (id, timestamp) in [("older", 1_000.0), ("newer", 9_000.0)] {
      let measurement = makeMeasurement(id: id, createdAt: Date(timeIntervalSince1970: timestamp))
      try await store.saveMeasurement(
        SessionMeasurementRecord(measurement: measurement, projectPath: "/tmp/project", sessionId: "session-1")
      )
    }

    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project").map(\.id) == ["newer", "older"])
  }

  @Test("Re-saving the same id replaces rather than duplicates")
  func resavingReplacesRatherThanDuplicates() async throws {
    let store = try SessionMetadataStore(path: temporaryMeasurementDatabasePath())
    try await store.saveMeasurement(SessionMeasurementRecord(
      measurement: makeMeasurement(id: "measurement-1", claim: "First reading."),
      projectPath: "/tmp/project",
      sessionId: "session-1"
    ))
    try await store.saveMeasurement(SessionMeasurementRecord(
      measurement: makeMeasurement(id: "measurement-1", claim: "Corrected reading."),
      projectPath: "/tmp/project",
      sessionId: "session-1"
    ))

    let stored = try await store.getMeasurements(forProjectPath: "/tmp/project")
    #expect(stored.count == 1)
    #expect(try stored.first?.decodedMeasurement().claim == "Corrected reading.")
  }

  /// The whole reason measurements moved off session scope: two sessions working on
  /// the same project must see one shared set, or last month's number is
  /// invisible exactly when you want to compare against it.
  @Test("Measurements are shared across sessions and providers in the same project")
  func measurementsAreSharedAcrossSessionsAndProviders() async throws {
    let store = try SessionMetadataStore(path: temporaryMeasurementDatabasePath())

    try await store.saveMeasurement(SessionMeasurementRecord(
      measurement: makeMeasurement(id: "from-claude", provider: .claude),
      projectPath: "/tmp/project",
      sessionId: "claude-session"
    ))
    try await store.saveMeasurement(SessionMeasurementRecord(
      measurement: makeMeasurement(id: "from-codex", provider: .codex),
      projectPath: "/tmp/project",
      sessionId: "codex-session"
    ))

    let stored = try await store.getMeasurements(forProjectPath: "/tmp/project")
    #expect(Set(stored.map(\.id)) == ["from-claude", "from-codex"])
    #expect(Set(stored.map(\.sessionId)) == ["claude-session", "codex-session"])
  }

  @Test("Measurements are scoped to their own project")
  func measurementsAreScopedToProject() async throws {
    let store = try SessionMetadataStore(path: temporaryMeasurementDatabasePath())
    try await store.saveMeasurement(
      SessionMeasurementRecord(measurement: makeMeasurement(id: "a"), projectPath: "/tmp/alpha", sessionId: "s1")
    )
    try await store.saveMeasurement(
      SessionMeasurementRecord(measurement: makeMeasurement(id: "b"), projectPath: "/tmp/beta", sessionId: "s2")
    )

    #expect(try await store.getMeasurements(forProjectPath: "/tmp/alpha").map(\.id) == ["a"])
    #expect(try await store.getProjectPathsWithMeasurements() == ["/tmp/alpha", "/tmp/beta"])
  }

  @Test("Project lookup normalizes the path")
  func projectLookupNormalizesPath() async throws {
    let store = try SessionMetadataStore(path: temporaryMeasurementDatabasePath())
    try await store.saveMeasurement(
      SessionMeasurementRecord(measurement: makeMeasurement(id: "a"), projectPath: "/tmp/project", sessionId: "s1")
    )

    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project/").map(\.id) == ["a"])
    #expect(try await store.getMeasurements(forProjectPath: "/tmp/nested/../project").map(\.id) == ["a"])
  }

  @Test("Deleting one card leaves the rest of the project's measurements")
  func deletingOneCardLeavesTheRest() async throws {
    let store = try SessionMetadataStore(path: temporaryMeasurementDatabasePath())
    for id in ["a", "b"] {
      try await store.saveMeasurement(
        SessionMeasurementRecord(measurement: makeMeasurement(id: id), projectPath: "/tmp/project", sessionId: "s1")
      )
    }

    try await store.deleteMeasurement(id: "a")

    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project").map(\.id) == ["b"])
  }

  /// Rows with no resolved project can never be shown again, so they must be
  /// collectable rather than accumulating invisibly forever.
  @Test("Unscoped measurements can be swept")
  func unscopedMeasurementsCanBeSwept() async throws {
    let path = temporaryMeasurementDatabasePath()
    let store = try SessionMetadataStore(path: path)
    try await store.saveMeasurement(
      SessionMeasurementRecord(measurement: makeMeasurement(id: "orphan"), projectPath: "", sessionId: "s1")
    )
    try await store.saveMeasurement(
      SessionMeasurementRecord(measurement: makeMeasurement(id: "kept"), projectPath: "/tmp/project", sessionId: "s1")
    )

    #expect(try await store.deleteUnscopedMeasurements() == 1)
    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project").map(\.id) == ["kept"])
  }

  @Test("Measurements survive reopening the database")
  func measurementsSurviveReopen() async throws {
    let path = temporaryMeasurementDatabasePath()
    let store = try SessionMetadataStore(path: path)
    try await store.saveMeasurement(
      SessionMeasurementRecord(measurement: makeMeasurement(id: "measurement-1"), projectPath: "/tmp/project", sessionId: "s1")
    )

    let reopened = try SessionMetadataStore(path: path)
    #expect(try await reopened.getMeasurements(forProjectPath: "/tmp/project").map(\.id) == ["measurement-1"])
  }

  @Test("v14 migration preserves existing metadata")
  func v14MigrationPreservesExistingMetadata() async throws {
    let path = temporaryMeasurementDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)

    try await dbQueue.write { db in
      try seedMigrationBaseline(
        before: SessionMetadataStore.MigrationID.createSessionMeasurements,
        in: db
      )
      try seedLegacySessionMetadata(in: db)
    }

    let store = try SessionMetadataStore(path: path)

    #expect(try await store.getCustomName(for: "legacy-session") == "legacy-name")
    #expect(try await store.getPinnedSessionIds() == ["legacy-session"])
    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project").isEmpty)
  }

  /// v15 adds the project column to a table that already has rows; every one of
  /// them has to be backfilled from the payload it already carries, or existing
  /// measurements would silently vanish from the panel.
  @Test("v15 migration backfills the project path from existing payloads")
  func v15MigrationBackfillsProjectPath() async throws {
    let path = temporaryMeasurementDatabasePath()
    let dbQueue = try DatabaseQueue(path: path)
    let legacy = makeMeasurement(id: "legacy-measurement", projectPath: "/tmp/project/")
    let payload = try JSONEncoder.iso8601.encode(legacy)

    try await dbQueue.write { db in
      try seedMigrationBaseline(
        before: SessionMetadataStore.MigrationID.addMeasurementProjectPath,
        in: db
      )
      try seedLegacySessionMetadata(in: db)

      // The v14 shape: no projectPath column at all.
      try db.create(table: "session_measurements") { t in
        t.column("id", .text).primaryKey(onConflict: .replace)
        t.column("sessionId", .text).notNull().indexed()
        t.column("provider", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("payloadVersion", .integer).notNull()
        t.column("payloadData", .blob).notNull()
      }
      try db.execute(
        sql: """
        INSERT INTO session_measurements (id, sessionId, provider, createdAt, payloadVersion, payloadData)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        arguments: ["legacy-measurement", "legacy-session", "claude", Date(timeIntervalSince1970: 1_000), 1, payload]
      )
    }

    let store = try SessionMetadataStore(path: path)

    // Backfilled, normalized, and still readable — plus the older data intact.
    #expect(try await store.getMeasurements(forProjectPath: "/tmp/project").map(\.id) == ["legacy-measurement"])
    #expect(try await store.getCustomName(for: "legacy-session") == "legacy-name")
  }
}

// MARK: - History

@Suite("Measurement run history")
struct MeasurementRunHistoryTests {
  @Test("A first filing has no history and one run")
  func firstFilingHasNoHistory() {
    let measurement = makeMeasurement(id: "a")

    #expect(measurement.history == nil)
    #expect(measurement.runs.count == 1)
  }

  /// The compare use case: today's numbers must not erase last week's.
  @Test("Re-running pushes the superseded values onto the history")
  func rerunPushesSupersededValuesOntoHistory() {
    let first = makeMeasurement(id: "a", claim: "41s", value: 41, createdAt: Date(timeIntervalSince1970: 1_000))
    let second = makeMeasurement(id: "a", claim: "82s", value: 82, createdAt: Date(timeIntervalSince1970: 2_000))

    let merged = second.replacing(first)

    #expect(merged.claim == "82s")
    #expect(merged.history?.count == 1)
    #expect(merged.history?.first?.claim == "41s")
    #expect(merged.history?.first?.scalarValue == 41)
    #expect(merged.runs.map(\.scalarValue) == [41, 82])
  }

  @Test("History accumulates across several runs, oldest first")
  func historyAccumulatesAcrossRuns() {
    var record = makeMeasurement(id: "a", claim: "run-0", value: 0, createdAt: Date(timeIntervalSince1970: 0))
    for index in 1...4 {
      let next = makeMeasurement(
        id: "a",
        claim: "run-\(index)",
        value: Double(index),
        createdAt: Date(timeIntervalSince1970: TimeInterval(index) * 1_000)
      )
      record = next.replacing(record)
    }

    #expect(record.runs.map(\.claim) == ["run-0", "run-1", "run-2", "run-3", "run-4"])
    #expect(record.history?.count == 4)
  }

  /// One card must not grow without bound just because it is re-run often.
  @Test("History is capped, dropping the oldest runs")
  func historyIsCapped() {
    var record = makeMeasurement(id: "a", claim: "run-0", value: 0, createdAt: Date(timeIntervalSince1970: 0))
    for index in 1...(MeasurementRecord.Limits.maxHistoryRuns + 5) {
      let next = makeMeasurement(
        id: "a",
        claim: "run-\(index)",
        value: Double(index),
        createdAt: Date(timeIntervalSince1970: TimeInterval(index) * 1_000)
      )
      record = next.replacing(record)
    }

    #expect(record.history?.count == MeasurementRecord.Limits.maxHistoryRuns)
    #expect(record.history?.first?.claim != "run-0")
    #expect(record.claim == "run-\(MeasurementRecord.Limits.maxHistoryRuns + 5)")
  }

  @Test("History survives the SQLite round trip")
  func historySurvivesRoundTrip() async throws {
    let store = try SessionMetadataStore(path: temporaryMeasurementDatabasePath())
    let first = makeMeasurement(id: "a", claim: "41s", value: 41)
    let second = makeMeasurement(id: "a", claim: "82s", value: 82).replacing(first)

    try await store.saveMeasurement(
      SessionMeasurementRecord(measurement: second, projectPath: "/tmp/project", sessionId: "s1")
    )

    let decoded = try #require(
      try await store.getMeasurements(forProjectPath: "/tmp/project").first?.decodedMeasurement()
    )
    #expect(decoded.runs.map(\.scalarValue) == [41, 82])
  }

  @Test("Only single-series single-point measurements expose a scalar")
  func onlyScalarMeasurementsExposeAValue() {
    #expect(makeMeasurement(id: "a", value: 41).scalarValue == 41)

    let multiPoint = MeasurementRecord(
      id: "b",
      title: "t",
      claim: "c",
      chart: MeasurementChart(kind: .line, series: [
        MeasurementSeries(name: "s", points: [MeasurementPoint(x: "1", y: 1), MeasurementPoint(x: "2", y: 2)])
      ]),
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 1
    )
    #expect(multiPoint.scalarValue == nil)
  }
}

// MARK: - Merge ordering

@MainActor
@Suite("Measurements merge ordering")
struct MeasurementsMergeTests {
  @Test("Merging keeps one card per id and orders newest first")
  func mergeDeduplicatesAndOrders() {
    let existing = [
      makeMeasurement(id: "a", createdAt: Date(timeIntervalSince1970: 1_000)),
      makeMeasurement(id: "b", createdAt: Date(timeIntervalSince1970: 3_000))
    ]
    let incoming = [makeMeasurement(id: "c", createdAt: Date(timeIntervalSince1970: 2_000))]

    let merged = CLISessionsViewModel.mergedMeasurements(existing: existing, incoming: incoming)

    #expect(merged.map(\.id) == ["b", "c", "a"])
  }

  /// A record arriving from the CLI queue can race the database read that
  /// backfills history; the newer copy must win rather than be replaced by the
  /// older snapshot landing second.
  @Test("Incoming wins on an id collision")
  func incomingWinsOnCollision() {
    let existing = [makeMeasurement(id: "a", claim: "Stale claim.")]
    let incoming = [makeMeasurement(id: "a", claim: "Fresh claim.")]

    let merged = CLISessionsViewModel.mergedMeasurements(existing: existing, incoming: incoming)

    #expect(merged.count == 1)
    #expect(merged.first?.claim == "Fresh claim.")
  }
}

// MARK: - Project scope

@Suite("Measurement project scope")
struct MeasurementProjectScopeTests {
  /// A worktree is the same project — splitting its measurements into their own
  /// bucket would fragment the very history the feature accumulates.
  @Test("A worktree rolls up to its parent repository")
  func worktreeRollsUpToParentRepo() {
    let key = MeasurementProjectScope.key(
      projectPath: "/Users/me/code/app-feature-branch",
      parentRepoPath: "/Users/me/code/app"
    )
    #expect(key == "/Users/me/code/app")
  }

  @Test("Without a parent repo the project path is used")
  func fallsBackToProjectPath() {
    #expect(MeasurementProjectScope.key(projectPath: "/Users/me/code/app", parentRepoPath: nil) == "/Users/me/code/app")
    #expect(MeasurementProjectScope.key(projectPath: "/Users/me/code/app", parentRepoPath: "  ") == "/Users/me/code/app")
  }

  @Test("The same directory written several ways lands in one bucket")
  func equivalentPathsNormalizeTogether() {
    let canonical = MeasurementProjectScope.normalized("/tmp/project")
    #expect(MeasurementProjectScope.normalized("/tmp/project/") == canonical)
    #expect(MeasurementProjectScope.normalized("/tmp/nested/../project") == canonical)
    #expect(MeasurementProjectScope.normalized("  /tmp/project  ") == canonical)
  }

  @Test("Root is not mangled by trailing-slash trimming")
  func rootSurvivesNormalization() {
    #expect(MeasurementProjectScope.normalized("/") == "/")
  }
}

// MARK: - Helpers

private extension JSONEncoder {
  static var iso8601: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

private func seedLegacySessionMetadata(in db: Database) throws {
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
      true
    ]
  )
}

private func makeMeasurement(
  id: String,
  claim: String = "GitDiffServiceTests alone is 41s.",
  value: Double = 41,
  createdAt: Date = Date(timeIntervalSince1970: 3_000),
  provider: WorktreeLaunchProvider = .claude,
  projectPath: String = "/tmp/project"
) -> MeasurementRecord {
  MeasurementRecord(
    id: id,
    createdAt: createdAt,
    title: "Slowest test suites",
    claim: claim,
    query: "xcodebuild test -scheme AgentHubCore-Tests",
    source: "AgentHubCore-Tests",
    caveats: ["Single run, no warm cache"],
    chart: MeasurementChart(
      kind: .bar,
      yLabel: "Seconds",
      series: [MeasurementSeries(name: "Duration", points: [MeasurementPoint(x: "GitDiff", y: value)])]
    ),
    sourceProvider: provider,
    sourceSessionId: "session-1",
    sourceProjectPath: projectPath,
    sourceProcessId: 42
  )
}

private func temporaryMeasurementDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "session_measurements_\(UUID().uuidString).sqlite")
    .path
}
