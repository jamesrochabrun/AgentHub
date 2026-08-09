import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Measurements settings")
struct MeasurementsSettingsViewModelTests {
  /// Grouping is by project. Worktrees roll up to their parent repo, so there
  /// is deliberately no per-worktree group to delete — offering one would mean
  /// deleting a worktree's measurements and finding the card still there.
  @Test("Measurements group by project, most recently active first")
  func groupsByProjectMostRecentFirst() {
    let decoded = [
      ("/tmp/alpha", makeMeasurement(id: "a1", at: 1_000)),
      ("/tmp/beta", makeMeasurement(id: "b1", at: 9_000)),
      ("/tmp/alpha", makeMeasurement(id: "a2", at: 5_000))
    ]

    let groups = MeasurementsSettingsViewModel.grouped(decoded)

    #expect(groups.map(\.projectPath) == ["/tmp/beta", "/tmp/alpha"])
    #expect(groups[1].measurements.map(\.id) == ["a2", "a1"])
  }

  @Test("A group reports its display name, count and run total")
  func groupSummarizesItself() {
    let first = makeMeasurement(id: "a", at: 1_000)
    let rerun = makeMeasurement(id: "b", at: 2_000).replacing(makeMeasurement(id: "b", at: 1_500))

    let group = MeasurementProjectGroup(
      projectPath: "/Users/me/code/AgentHub",
      measurements: [first, rerun]
    )

    #expect(group.displayName == "AgentHub")
    #expect(group.measurements.count == 2)
    // One run for the first, two for the one that has been re-run.
    #expect(group.runCount == 3)
    #expect(group.lastActivityAt == Date(timeIntervalSince1970: 2_000))
  }

  /// A re-run does not change the stored creation date, so ordering on it would
  /// make an actively-refreshed project look stale.
  @Test("Last activity follows the latest run, not the original filing")
  func lastActivityFollowsLatestRun() {
    let old = makeMeasurement(id: "a", at: 1_000)
    let refreshed = makeMeasurement(id: "a", at: 9_000).replacing(old)

    let group = MeasurementProjectGroup(projectPath: "/tmp/p", measurements: [refreshed])

    #expect(group.createdAtForTesting == Date(timeIntervalSince1970: 1_000))
    #expect(group.lastActivityAt == Date(timeIntervalSince1970: 9_000))
  }

  @Test("A project path with a trailing component still yields a readable name")
  func displayNameFallsBackToPath() {
    #expect(MeasurementProjectGroup(projectPath: "/", measurements: []).displayName == "/")
    #expect(MeasurementProjectGroup(projectPath: "/tmp/x", measurements: []).displayName == "x")
  }
}

private extension MeasurementProjectGroup {
  var createdAtForTesting: Date? {
    measurements.map(\.createdAt).min()
  }
}

private func makeMeasurement(id: String, at seconds: TimeInterval) -> MeasurementRecord {
  MeasurementRecord(
    id: id,
    createdAt: Date(timeIntervalSince1970: seconds),
    title: "Clean build time",
    claim: "163s",
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
