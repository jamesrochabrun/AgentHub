import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Measurement re-run")
struct MeasurementRerunTests {
  @Test("A measurement without a query cannot be re-run")
  func measurementWithoutQueryCannotBeRerun() {
    #expect(!MeasurementRerunPromptBuilder.canRerun(makeMeasurement(query: nil)))
    #expect(!MeasurementRerunPromptBuilder.canRerun(makeMeasurement(query: "   \n  ")))
    #expect(MeasurementRerunPromptBuilder.canRerun(makeMeasurement(query: "git log --oneline")))
    #expect(MeasurementRerunPromptBuilder.prompt(for: makeMeasurement(query: nil)) == nil)
  }

  /// The id is what makes a re-run refresh the card instead of stacking a
  /// near-duplicate under it, so it has to survive into the prompt.
  @Test("The prompt carries the id, title and query verbatim")
  func promptCarriesIdentityAndQuery() throws {
    let measurement = makeMeasurement(query: "git log --since='12 months ago' --name-only")
    let prompt = try #require(MeasurementRerunPromptBuilder.prompt(for: measurement))

    #expect(prompt.contains(measurement.id))
    #expect(prompt.contains(measurement.title))
    #expect(prompt.contains("git log --since='12 months ago' --name-only"))
    #expect(prompt.contains("agenthub_record_measurement"))
  }

  @Test("The prompt forbids rewriting the query and forbids recording on failure")
  func promptPinsTheMeasurement() throws {
    let prompt = try #require(MeasurementRerunPromptBuilder.prompt(for: makeMeasurement(query: "echo 1")))

    #expect(prompt.contains("exactly as written"))
    #expect(prompt.contains("do not record a measurement"))
  }

  @Test("Re-filing under a known id keeps the original creation date")
  func rerunPreservesCreationDate() {
    let original = makeMeasurement(
      id: "measurement-1",
      createdAt: Date(timeIntervalSince1970: 1_000),
      claim: "41s"
    )
    let refreshed = makeMeasurement(
      id: "measurement-1",
      createdAt: Date(timeIntervalSince1970: 9_000),
      claim: "22s"
    )

    let resolved = CLISessionsViewModel.resolvingRerun(incoming: refreshed, against: [original])

    #expect(resolved.createdAt == Date(timeIntervalSince1970: 1_000))
    #expect(resolved.updatedAt == Date(timeIntervalSince1970: 9_000))
    #expect(resolved.displayDate == Date(timeIntervalSince1970: 9_000))
    #expect(resolved.claim == "22s")
    #expect(resolved.hasBeenRerun)
  }

  /// Sorting is by creation date, so a preserved date is what stops a refreshed
  /// card from jumping to the top of the panel under the user's cursor.
  @Test("A refreshed card holds its position in the panel")
  func refreshedCardHoldsItsPosition() {
    let older = makeMeasurement(id: "older", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = makeMeasurement(id: "newer", createdAt: Date(timeIntervalSince1970: 5_000))
    let existing = [newer, older]

    let refreshedOlder = makeMeasurement(id: "older", createdAt: Date(timeIntervalSince1970: 9_000))
    let resolved = CLISessionsViewModel.resolvingRerun(incoming: refreshedOlder, against: existing)
    let merged = CLISessionsViewModel.mergedMeasurements(existing: existing, incoming: [resolved])

    #expect(merged.map(\.id) == ["newer", "older"])
  }

  @Test("A first-time measurement is not marked as updated")
  func firstFilingIsNotMarkedUpdated() {
    let measurement = makeMeasurement(id: "fresh", createdAt: Date(timeIntervalSince1970: 1_000))
    let resolved = CLISessionsViewModel.resolvingRerun(incoming: measurement, against: [])

    #expect(resolved.updatedAt == nil)
    #expect(!resolved.hasBeenRerun)
    #expect(resolved.displayDate == Date(timeIntervalSince1970: 1_000))
  }
}

@Suite("Measurement axis label layout")
struct MeasurementAxisLabelLayoutTests {
  /// The bug this replaced rotated seven three-letter labels purely because
  /// there were more than six of them.
  @Test("Short labels stay horizontal even when there are many")
  func shortLabelsStayHorizontal() {
    let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    #expect(MeasurementAxisLabelLayout.orientation(forCategories: days) == .horizontal)
  }

  @Test("Long labels rotate even when there are few")
  func longLabelsRotate() {
    let files = [
      "CLISessionsViewModel.swift",
      "MonitoringCardView.swift",
      "MultiProviderPanel.swift",
      "GitDiffView.swift"
    ]
    #expect(MeasurementAxisLabelLayout.orientation(forCategories: files) == .rotated)
  }

  @Test("Repeated categories across series are not double counted")
  func repeatedCategoriesAreDeduplicated() {
    // Two series over the same seven days must not read as fourteen columns.
    let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    #expect(MeasurementAxisLabelLayout.orientation(forCategories: days + days) == .horizontal)
  }

  @Test("No categories is handled without rotating")
  func emptyCategoriesStayHorizontal() {
    #expect(MeasurementAxisLabelLayout.orientation(forCategories: []) == .horizontal)
  }
}

// MARK: - Helpers

private func makeMeasurement(
  id: String = "measurement-1",
  createdAt: Date = Date(timeIntervalSince1970: 3_000),
  claim: String = "GitDiffServiceTests alone is 41s.",
  query: String? = "xcodebuild test -scheme AgentHubCore-Tests"
) -> MeasurementRecord {
  MeasurementRecord(
    id: id,
    createdAt: createdAt,
    title: "Slowest test suites",
    claim: claim,
    query: query,
    chart: MeasurementChart(
      kind: .bar,
      series: [MeasurementSeries(name: "Duration", points: [MeasurementPoint(x: "GitDiff", y: 41)])]
    ),
    sourceProvider: .claude,
    sourceSessionId: "session-1",
    sourceProcessId: 42
  )
}
