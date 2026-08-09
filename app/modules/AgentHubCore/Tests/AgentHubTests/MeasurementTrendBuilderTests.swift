import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Measurement trend by branch")
struct MeasurementTrendBuilderTests {
  /// The bug this exists to prevent: `main` and a feature branch are each
  /// perfectly stable, but interleaved into one series they read 214 → 163 →
  /// 211 → 160, which looks like a metric thrashing.
  @Test("Runs from different branches plot as separate series")
  func branchesPlotAsSeparateSeries() throws {
    let runs = [
      makeRun(day: 1, value: 214, branch: "main"),
      makeRun(day: 2, value: 163, branch: "refactor"),
      makeRun(day: 3, value: 211, branch: "main"),
      makeRun(day: 4, value: 160, branch: "refactor")
    ]

    let chart = try #require(MeasurementTrendBuilder.chart(for: runs, title: "Build time"))

    #expect(chart.series.map(\.name) == ["main", "refactor"])
    #expect(chart.series[0].points.map(\.y) == [214, 211])
    #expect(chart.series[1].points.map(\.y) == [163, 160])
  }

  /// Swift Charts derives a category axis from first-appearance order, which
  /// for a branch split groups one branch's dates before the other's — the axis
  /// then read 12 Jul, 26 Jul, 19 Jul, 7 Aug.
  @Test("The axis is ordered by date across every branch")
  func axisIsChronologicalAcrossBranches() throws {
    let runs = [
      makeRun(day: 1, value: 214, branch: "main"),
      makeRun(day: 8, value: 163, branch: "refactor"),
      makeRun(day: 15, value: 211, branch: "main"),
      makeRun(day: 22, value: 160, branch: "refactor")
    ]

    let chart = try #require(MeasurementTrendBuilder.chart(for: runs, title: "Build time"))
    let expected = runs
      .sorted { $0.runAt < $1.runAt }
      .map { MeasurementTrendBuilder.label(for: $0.runAt) }

    #expect(chart.xOrder == expected)
  }

  @Test("Two branches measured on the same day share one axis slot")
  func sameDayRunsShareAnAxisSlot() throws {
    let runs = [
      makeRun(day: 1, value: 214, branch: "main"),
      makeRun(day: 1, value: 163, branch: "refactor")
    ]

    let chart = try #require(MeasurementTrendBuilder.chart(for: runs, title: "Build time"))
    #expect(chart.xOrder?.count == 1)
    #expect(chart.series.count == 2)
  }

  @Test("A single branch stays one series named for the branch")
  func singleBranchStaysOneSeries() throws {
    let runs = [
      makeRun(day: 1, value: 214, branch: "main"),
      makeRun(day: 2, value: 198, branch: "main")
    ]

    let chart = try #require(MeasurementTrendBuilder.chart(for: runs, title: "Build time"))

    #expect(chart.series.count == 1)
    #expect(chart.series[0].name == "main")
  }

  /// Runs recorded before branches were tracked have no branch; they must still
  /// plot rather than being silently dropped.
  @Test("Runs without a branch fall back to the measurement title")
  func runsWithoutBranchFallBackToTitle() throws {
    let runs = [
      makeRun(day: 1, value: 214, branch: nil),
      makeRun(day: 2, value: 198, branch: nil)
    ]

    let chart = try #require(MeasurementTrendBuilder.chart(for: runs, title: "Build time"))

    #expect(chart.series.map(\.name) == ["Build time"])
    #expect(chart.series[0].points.count == 2)
  }

  @Test("Legend order follows whichever branch was measured first")
  func legendOrderFollowsFirstMeasurement() throws {
    let runs = [
      makeRun(day: 1, value: 163, branch: "refactor"),
      makeRun(day: 2, value: 214, branch: "main")
    ]

    let chart = try #require(MeasurementTrendBuilder.chart(for: runs, title: "Build time"))
    #expect(chart.series.map(\.name) == ["refactor", "main"])
  }

  @Test("A single run is not a trend")
  func singleRunIsNotATrend() {
    #expect(MeasurementTrendBuilder.chart(for: [makeRun(day: 1, value: 1, branch: "main")], title: "t") == nil)
  }

  @Test("A multi-series measurement has no scalar trend")
  func multiSeriesHasNoTrend() {
    let breakdown = MeasurementRun(
      runAt: Date(timeIntervalSince1970: 1_000),
      claim: "c",
      chart: MeasurementChart(kind: .bar, series: [
        MeasurementSeries(name: "s", points: [
          MeasurementPoint(x: "a", y: 1),
          MeasurementPoint(x: "b", y: 2)
        ])
      ]),
      table: nil,
      branchName: "main"
    )

    #expect(MeasurementTrendBuilder.chart(for: [breakdown, breakdown], title: "t") == nil)
  }

  @Test("Branch labels only show once runs actually span branches")
  func branchLabelsOnlyWhenTheySpanBranches() {
    let sameBranch = [makeRun(day: 1, value: 1, branch: "main"), makeRun(day: 2, value: 2, branch: "main")]
    let twoBranches = [makeRun(day: 1, value: 1, branch: "main"), makeRun(day: 2, value: 2, branch: "dev")]

    #expect(!MeasurementTrendBuilder.spansMultipleBranches(sameBranch))
    #expect(MeasurementTrendBuilder.spansMultipleBranches(twoBranches))
  }
}

@Suite("Measurement branch stamping")
struct MeasurementBranchStampingTests {
  /// The branch has to travel into history with the values it measured,
  /// otherwise every earlier run looks like it happened on today's branch.
  @Test("A superseded run carries the branch it was measured on")
  func supersededRunCarriesItsBranch() {
    let onMain = makeMeasurement(value: 214).stamped(branchName: "main", worktreePath: nil)
    let onRefactor = makeMeasurement(value: 163)
      .stamped(branchName: "refactor", worktreePath: "/tmp/wt")
      .replacing(onMain)

    #expect(onRefactor.branchName == "refactor")
    #expect(onRefactor.worktreePath == "/tmp/wt")
    #expect(onRefactor.history?.first?.branchName == "main")
    #expect(onRefactor.runs.map(\.branchName) == ["main", "refactor"])
  }

  @Test("Stamping preserves everything else about the record")
  func stampingPreservesTheRest() {
    let original = makeMeasurement(value: 214)
    let stamped = original.stamped(branchName: "main", worktreePath: nil)

    #expect(stamped.id == original.id)
    #expect(stamped.createdAt == original.createdAt)
    #expect(stamped.claim == original.claim)
    #expect(stamped.query == original.query)
    #expect(stamped.chart == original.chart)
  }
}

// MARK: - Helpers

private func makeRun(day: Int, value: Double, branch: String?) -> MeasurementRun {
  MeasurementRun(
    runAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400),
    claim: "\(Int(value))s",
    chart: MeasurementChart(
      kind: .bar,
      series: [MeasurementSeries(name: "Build", points: [MeasurementPoint(x: "core", y: value)])]
    ),
    table: nil,
    branchName: branch
  )
}

private func makeMeasurement(value: Double) -> MeasurementRecord {
  MeasurementRecord(
    id: "build-time",
    createdAt: Date(timeIntervalSince1970: 1_000),
    title: "Clean build time",
    claim: "\(Int(value))s",
    query: "xcodebuild build",
    chart: MeasurementChart(
      kind: .bar,
      series: [MeasurementSeries(name: "Build", points: [MeasurementPoint(x: "core", y: value)])]
    ),
    sourceProvider: .claude,
    sourceSessionId: "session-1",
    sourceProcessId: 1
  )
}
