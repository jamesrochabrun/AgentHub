import Combine
import Foundation
import Testing

@testable import AgentHubCore

private actor AuxiliaryShellStubMonitorService: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private actor AuxiliaryShellStubFileWatcher: SessionFileWatcherProtocol {
  private nonisolated let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()

  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

@MainActor
private func makeAuxiliaryShellViewModel() -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: AuxiliaryShellStubMonitorService(),
    fileWatcher: AuxiliaryShellStubFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude
  )
}

@Suite("Auxiliary shell terminal management")
struct AuxiliaryShellTerminalManagementTests {

  @Test("Transfers auxiliary shell terminal from pending key to resolved session ID")
  @MainActor
  func transferAuxiliaryShellTerminal() {
    let viewModel = makeAuxiliaryShellViewModel()
    let pendingID = UUID()
    let pendingKey = "pending-\(pendingID.uuidString)"
    let terminal = TerminalContainerView()
    viewModel.auxiliaryShellTerminals[pendingKey] = terminal

    viewModel.transferAuxiliaryShellTerminal(fromPendingId: pendingID, toSessionId: "session-123")

    #expect(viewModel.auxiliaryShellTerminals[pendingKey] == nil)
    #expect(viewModel.auxiliaryShellTerminals["session-123"] === terminal)
  }

  @Test("Canceling pending session removes auxiliary shell terminal")
  @MainActor
  func cancelPendingSessionRemovesAuxiliaryShell() {
    let viewModel = makeAuxiliaryShellViewModel()
    let pending = PendingHubSession(
      worktree: WorktreeBranch(name: "feature", path: "/tmp/feature", isWorktree: true)
    )
    let pendingKey = "pending-\(pending.id.uuidString)"
    viewModel.pendingHubSessions = [pending]
    viewModel.auxiliaryShellTerminals[pendingKey] = TerminalContainerView()

    viewModel.cancelPendingSession(pending)

    #expect(viewModel.pendingHubSessions.isEmpty)
    #expect(viewModel.auxiliaryShellTerminals[pendingKey] == nil)
  }

  @Test("Managed terminal entries include auxiliary shells")
  @MainActor
  func managedTerminalEntriesIncludeAuxiliaryShells() {
    let viewModel = makeAuxiliaryShellViewModel()
    viewModel.activeTerminals["session-123"] = TerminalContainerView()
    viewModel.auxiliaryShellTerminals["session-123"] = TerminalContainerView()

    let keys = viewModel.managedTerminalEntries.map(\.key)

    #expect(keys.contains("session-123"))
    #expect(keys.contains("shell:session-123"))
    #expect(keys.count == 2)
  }

  @Test("Stopping monitoring removes and terminates both terminal surfaces for the session")
  @MainActor
  func stopMonitoringRemovesAndTerminatesSessionTerminals() {
    let viewModel = makeAuxiliaryShellViewModel()
    let session = CLISession(
      id: "session-123",
      projectPath: "/tmp/project",
      branchName: "main"
    )
    let agentTerminal = TerminalContainerView()
    let shellTerminal = TerminalContainerView()

    viewModel.startMonitoring(session: session)
    viewModel.activeTerminals[session.id] = agentTerminal
    viewModel.auxiliaryShellTerminals[session.id] = shellTerminal

    viewModel.stopMonitoring(sessionId: session.id)

    #expect(!viewModel.isMonitoring(sessionId: session.id))
    #expect(viewModel.activeTerminals[session.id] == nil)
    #expect(viewModel.auxiliaryShellTerminals[session.id] == nil)
    #expect(agentTerminal.terminateProcessCallCount == 1)
    #expect(shellTerminal.terminateProcessCallCount == 1)
  }
}
