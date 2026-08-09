import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("MeasurementIndexStore")
struct MeasurementIndexStoreTests {
  @Test("An index round-trips with the query the agent needs to re-run")
  func indexRoundTrips() throws {
    let directory = try temporaryIndexDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = MeasurementIndexStore(directoryURL: directory)
    try store.write(makeIndex(projectPath: "/tmp/project"))

    let read = try #require(store.read(projectPath: "/tmp/project"))
    #expect(read.measurements.map(\.id) == ["measurement-1"])
    #expect(read.measurements.first?.query == "xcodebuild build")
    #expect(read.measurements.first?.runCount == 3)
  }

  /// The CLI only knows `AGENTHUB_PROJECT_PATH`, which for a worktree session is
  /// the worktree — not the repo the measurements are filed under. Mirroring to
  /// aliases is what lets it find the list anyway.
  @Test("Aliases resolve a worktree path to the parent repo's index")
  func aliasesResolveWorktreePaths() throws {
    let directory = try temporaryIndexDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = MeasurementIndexStore(directoryURL: directory)
    try store.write(
      makeIndex(projectPath: "/Users/me/code/app"),
      aliasPaths: ["/Users/me/code/app-feature"]
    )

    #expect(store.read(projectPath: "/Users/me/code/app-feature")?.measurements.count == 1)
    #expect(store.read(projectPath: "/Users/me/code/app-feature")?.projectPath == "/Users/me/code/app")
  }

  @Test("An unknown project reads back as nothing rather than failing")
  func unknownProjectReadsBackNil() throws {
    let directory = try temporaryIndexDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    #expect(MeasurementIndexStore(directoryURL: directory).read(projectPath: "/tmp/nothing") == nil)
  }

  @Test("Rewriting replaces the previous index rather than appending")
  func rewritingReplaces() throws {
    let directory = try temporaryIndexDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = MeasurementIndexStore(directoryURL: directory)
    try store.write(makeIndex(projectPath: "/tmp/project"))
    try store.write(MeasurementIndex(projectPath: "/tmp/project", updatedAt: .now, measurements: []))

    #expect(store.read(projectPath: "/tmp/project")?.measurements.isEmpty == true)
  }

  /// Substituting separators (`/` → `-`) would make these two collide and
  /// silently merge two projects' measurements.
  @Test("Similar paths do not collide on disk")
  func similarPathsDoNotCollide() {
    let first = MeasurementIndexStore.fileName(forProjectPath: "/a/b-c")
    let second = MeasurementIndexStore.fileName(forProjectPath: "/a-b/c")
    #expect(first != second)
  }

  @Test("An index entry summarizes a measurement including its run count")
  func entrySummarizesMeasurement() {
    let first = makeMeasurement(claim: "214s")
    let second = makeMeasurement(claim: "163s").replacing(first)
    let entry = MeasurementIndexEntry(measurement: second)

    #expect(entry.latestClaim == "163s")
    #expect(entry.runCount == 2)
    #expect(entry.query == "xcodebuild build")
  }
}

private func makeIndex(projectPath: String) -> MeasurementIndex {
  MeasurementIndex(
    projectPath: projectPath,
    updatedAt: Date(timeIntervalSince1970: 5_000),
    measurements: [
      MeasurementIndexEntry(
        id: "measurement-1",
        title: "Clean build time",
        question: "Is the build getting slower?",
        query: "xcodebuild build",
        source: "xcodebuild",
        lastRunAt: Date(timeIntervalSince1970: 4_000),
        runCount: 3,
        latestClaim: "Clean build is 163s."
      )
    ]
  )
}

private func makeMeasurement(claim: String) -> MeasurementRecord {
  MeasurementRecord(
    id: "measurement-1",
    title: "Clean build time",
    claim: claim,
    query: "xcodebuild build",
    chart: MeasurementChart(
      kind: .bar,
      series: [MeasurementSeries(name: "Build", points: [MeasurementPoint(x: "core", y: 163)])]
    ),
    sourceProvider: .claude,
    sourceSessionId: "session-1",
    sourceProcessId: 1
  )
}

private func temporaryIndexDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-measurement-index-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("index", isDirectory: true)
}
