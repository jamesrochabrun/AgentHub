import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionInvestigationViewModel")
@MainActor
struct SessionInvestigationViewModelTests {

  @Test("Start publishes completed report")
  func startPublishesCompletedReport() async throws {
    let report = makeReport()
    let service = StubSessionInvestigationService(report: report)
    let viewModel = SessionInvestigationViewModel(service: service)

    viewModel.start(snapshot: makeSnapshot())
    try await waitUntil { viewModel.report != nil }

    #expect(viewModel.isRunning == false)
    #expect(viewModel.statusMessage == "Local fallback complete")
    #expect(viewModel.report?.narrative == "Done")
  }

  @Test("Cancel forwards to service")
  func cancelForwardsToService() async throws {
    let service = StubSessionInvestigationService(report: makeReport())
    let viewModel = SessionInvestigationViewModel(service: service)

    viewModel.start(snapshot: makeSnapshot())
    viewModel.cancel()
    try await waitUntil { await service.cancelCount() == 1 }

    #expect(viewModel.isRunning == false)
    #expect(viewModel.statusMessage == "Investigation cancelled")
  }

  private func makeSnapshot() -> SessionInvestigationSnapshot {
    SessionInvestigationSnapshot(
      repositories: [],
      worktrees: [],
      sessions: []
    )
  }

  private func makeReport() -> SessionInvestigationReport {
    SessionInvestigationReport(
      source: .deterministicFallback,
      overview: makeSnapshot().overview,
      narrative: "Done",
      findings: [],
      actions: []
    )
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
      if await condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Condition was not met before timeout")
  }
}

private actor StubSessionInvestigationService: SessionInvestigationServiceProtocol {
  private let report: SessionInvestigationReport
  private var cancellations = 0

  init(report: SessionInvestigationReport) {
    self.report = report
  }

  func investigate(snapshot: SessionInvestigationSnapshot) async throws -> SessionInvestigationReport {
    try await Task.sleep(for: .milliseconds(50))
    return report
  }

  func cancelActiveInvestigation() async {
    cancellations += 1
  }

  func cancelCount() -> Int {
    cancellations
  }
}
