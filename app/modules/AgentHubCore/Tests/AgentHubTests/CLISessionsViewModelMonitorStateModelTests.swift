import Combine
import Foundation
import Testing

@testable import AgentHubCore

private final class MonitorStateModelMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
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

private final class MonitorStateModelFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()

  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  func send(sessionId: String, state: SessionMonitorState) {
    subject.send(SessionFileWatcher.StateUpdate(sessionId: sessionId, state: state))
  }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

@MainActor
private func makeMonitorStateModelViewModel(
  fileWatcher: MonitorStateModelFileWatcher
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: MonitorStateModelMonitorService(),
    fileWatcher: fileWatcher,
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
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

@Suite("CLISessionsViewModel monitor state models")
struct CLISessionsViewModelMonitorStateModelTests {
  @Test("State publisher updates only the matching per-session state model")
  @MainActor
  func statePublisherUpdatesMatchingStateModel() async throws {
    let fileWatcher = MonitorStateModelFileWatcher()
    let viewModel = makeMonitorStateModelViewModel(fileWatcher: fileWatcher)
    let first = CLISession(id: "session-1", projectPath: "/tmp/project-a")
    let second = CLISession(id: "session-2", projectPath: "/tmp/project-b")

    viewModel.startMonitoring(session: first)
    viewModel.startMonitoring(session: second)

    let firstModel = viewModel.monitorStateModel(for: first.id)
    let secondModel = viewModel.monitorStateModel(for: second.id)
    let updatedState = SessionMonitorState(
      status: .thinking,
      lastActivityAt: Date(timeIntervalSince1970: 1_000),
      messageCount: 3
    )

    fileWatcher.send(sessionId: first.id, state: updatedState)

    try await waitUntil {
      firstModel.state == updatedState
    }

    #expect(secondModel.state == nil)
    #expect(viewModel.monitorStates[first.id] == updatedState)
    #expect(viewModel.monitorStateModel(for: first.id) === firstModel)

    let presentation = try #require(
      viewModel.monitoredSessionPresentations.first { $0.session.id == first.id }
    )
    #expect(presentation.stateModel === firstModel)
  }

  @Test("Stopping monitoring removes the per-session state model")
  @MainActor
  func stoppingMonitoringRemovesStateModel() {
    let fileWatcher = MonitorStateModelFileWatcher()
    let viewModel = makeMonitorStateModelViewModel(fileWatcher: fileWatcher)
    let session = CLISession(id: "session-1", projectPath: "/tmp/project")

    viewModel.startMonitoring(session: session)
    let stateModel = viewModel.monitorStateModel(for: session.id)

    #expect(viewModel.existingMonitorStateModel(for: session.id) === stateModel)

    viewModel.stopMonitoring(session: session)

    #expect(viewModel.existingMonitorStateModel(for: session.id) == nil)
    #expect(viewModel.monitorStates[session.id] == nil)
    #expect(viewModel.monitoredSessionPresentations.isEmpty)
  }
}
