import AgentHubGitDiff
import Combine
import Foundation
import Testing

@testable import AgentHubCore

private final class DiffRefreshMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<[SelectedRepository], Never>()

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class DiffRefreshFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()

  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

/// Availability service whose `availability(for:)` suspends until `open()`,
/// letting tests observe the ViewModel's published state mid-evaluation.
private final class GatedDiffAvailabilityService: DiffAvailabilityServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var gateOpen: Bool
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var availabilityRequests = 0
  private let result: DiffAvailabilityStatus

  init(result: DiffAvailabilityStatus, gateOpen: Bool = false) {
    self.result = result
    self.gateOpen = gateOpen
  }

  func open() {
    lock.lock()
    gateOpen = true
    let resumed = waiters
    waiters = []
    lock.unlock()
    resumed.forEach { $0.resume() }
  }

  func close() {
    lock.lock()
    gateOpen = false
    lock.unlock()
  }

  func requestCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return availabilityRequests
  }

  func cachedAvailability(for projectPath: String) async -> DiffAvailabilityStatus? { nil }

  func availability(for projectPath: String) async -> DiffAvailabilityStatus {
    lock.lock()
    availabilityRequests += 1
    if gateOpen {
      lock.unlock()
      return result
    }
    lock.unlock()
    await withCheckedContinuation { continuation in
      lock.lock()
      if gateOpen {
        lock.unlock()
        continuation.resume()
        return
      }
      waiters.append(continuation)
      lock.unlock()
    }
    return result
  }

  func invalidate(projectPath: String) async {}
}

@MainActor
private func makeDiffRefreshViewModel(
  diffAvailabilityService: any DiffAvailabilityServiceProtocol
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: DiffRefreshMonitorService(),
    fileWatcher: DiffRefreshFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    diffAvailabilityService: diffAvailabilityService,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
}

@MainActor
private func waitUntil(
  _ condition: () -> Bool,
  timeoutAttempts: Int = 50
) async throws {
  for _ in 0..<timeoutAttempts {
    if condition() {
      return
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition())
}

@Suite("CLISessionsViewModel diff availability refresh")
struct CLISessionsViewModelDiffRefreshTests {
  @Test("Initial load surfaces .checking while the evaluation runs")
  @MainActor
  func initialLoadSurfacesChecking() async throws {
    let service = GatedDiffAvailabilityService(result: .available)
    let viewModel = makeDiffRefreshViewModel(diffAvailabilityService: service)
    let path = "/tmp/diff-refresh-project"
    let key = DiffAvailabilityService.normalize(path)

    let ensureTask = Task { await viewModel.ensureDiffAvailability(for: path) }
    try await waitUntil { service.requestCount() == 1 }
    #expect(viewModel.diffAvailability[key] == .checking)

    service.open()
    await ensureTask.value
    #expect(viewModel.diffAvailability[key] == .available)
  }

  @Test("Forced refresh keeps the previous status visible instead of flip-flopping to .checking")
  @MainActor
  func forcedRefreshKeepsPreviousStatusVisible() async throws {
    let service = GatedDiffAvailabilityService(result: .available, gateOpen: true)
    let viewModel = makeDiffRefreshViewModel(diffAvailabilityService: service)
    let path = "/tmp/diff-refresh-project"
    let key = DiffAvailabilityService.normalize(path)

    await viewModel.ensureDiffAvailability(for: path)
    #expect(viewModel.diffAvailability[key] == .available)

    // Second, forced refresh (the per-activity-tick path): the previous status
    // must stay visible while the evaluation is in flight.
    service.close()
    let refreshTask = Task { await viewModel.ensureDiffAvailability(for: path, forceRefresh: true) }
    try await waitUntil { service.requestCount() == 2 }
    #expect(viewModel.diffAvailability[key] == .available)
    #expect(viewModel.diffAvailability[key]?.isChecking == false)

    service.open()
    await refreshTask.value
    #expect(viewModel.diffAvailability[key] == .available)
  }
}
