import AgentHubGitHub
import Combine
import Foundation
import Observation
import Testing

@testable import AgentHubCore

private final class ProjectionMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
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

private final class ProjectionFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
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
private func makeProjectionViewModel(fileWatcher: ProjectionFileWatcher) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: ProjectionMonitorService(),
    fileWatcher: fileWatcher,
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
}

@MainActor
private func waitUntil(_ condition: () -> Bool, timeoutAttempts: Int = 50) async throws {
  for _ in 0..<timeoutAttempts {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition())
}

/// The session list renders only a status dot and PR links, but used to read the
/// whole `SessionMonitorState` — so a token counter ticking at ~10 Hz re-created
/// every sidebar row. These tests pin the narrow projections that fixed it.
@Suite("CLISessionsViewModel sidebar projections")
struct CLISessionsViewModelSidebarProjectionTests {

  @Test("Publishing populates the status and pull-request projections")
  @MainActor
  func publishPopulatesProjections() async throws {
    let fileWatcher = ProjectionFileWatcher()
    let viewModel = makeProjectionViewModel(fileWatcher: fileWatcher)
    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    viewModel.startMonitoring(session: session)

    fileWatcher.send(
      sessionId: session.id,
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        detectedResourceLinks: [
          ResourceLink(url: "https://github.com/owner/repo/pull/7"),
          ResourceLink(url: "https://example.com/not-a-pr")
        ]
      )
    )

    try await waitUntil { viewModel.sessionStatus(for: session.id) != nil }

    #expect(viewModel.sessionStatus(for: session.id) == .executingTool(name: "Bash"))
    #expect(viewModel.pullRequestReferences(for: session.id).map(\.number) == [7])
  }

  /// The regression this whole change exists for.
  @Test("A publish that moves only token counts does not invalidate the projections")
  @MainActor
  func tokenOnlyPublishDoesNotInvalidateProjections() async throws {
    let fileWatcher = ProjectionFileWatcher()
    let viewModel = makeProjectionViewModel(fileWatcher: fileWatcher)
    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    viewModel.startMonitoring(session: session)

    let links = [ResourceLink(url: "https://github.com/owner/repo/pull/7")]
    fileWatcher.send(
      sessionId: session.id,
      state: SessionMonitorState(status: .thinking, inputTokens: 10, detectedResourceLinks: links)
    )
    try await waitUntil { viewModel.sessionStatus(for: session.id) == .thinking }

    var statusesInvalidated = false
    withObservationTracking {
      _ = viewModel.sessionStatuses
    } onChange: {
      statusesInvalidated = true
    }

    var referencesInvalidated = false
    withObservationTracking {
      _ = viewModel.sessionPullRequestReferences
    } onChange: {
      referencesInvalidated = true
    }

    // Same status, same links, different token counts — what an agent mid-turn
    // emits on nearly every append. Fresh `ResourceLink` values on purpose: the
    // parser mints a new `UUID` per parse, so the projection must compare on the
    // derived references, not on link identity.
    fileWatcher.send(
      sessionId: session.id,
      state: SessionMonitorState(
        status: .thinking,
        inputTokens: 9_999,
        outputTokens: 1_234,
        messageCount: 42,
        detectedResourceLinks: [ResourceLink(url: "https://github.com/owner/repo/pull/7")]
      )
    )
    try await waitUntil { viewModel.monitorStates[session.id]?.inputTokens == 9_999 }

    #expect(!statusesInvalidated)
    #expect(!referencesInvalidated)
  }

  @Test("A status change does invalidate the status projection")
  @MainActor
  func statusChangeInvalidatesStatusProjection() async throws {
    let fileWatcher = ProjectionFileWatcher()
    let viewModel = makeProjectionViewModel(fileWatcher: fileWatcher)
    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    viewModel.startMonitoring(session: session)

    fileWatcher.send(sessionId: session.id, state: SessionMonitorState(status: .thinking))
    try await waitUntil { viewModel.sessionStatus(for: session.id) == .thinking }

    var statusesInvalidated = false
    withObservationTracking {
      _ = viewModel.sessionStatuses
    } onChange: {
      statusesInvalidated = true
    }

    fileWatcher.send(sessionId: session.id, state: SessionMonitorState(status: .waitingForUser))
    try await waitUntil { viewModel.sessionStatus(for: session.id) == .waitingForUser }

    #expect(statusesInvalidated)
  }

  @Test("A newly detected pull request invalidates the reference projection")
  @MainActor
  func newPullRequestInvalidatesReferenceProjection() async throws {
    let fileWatcher = ProjectionFileWatcher()
    let viewModel = makeProjectionViewModel(fileWatcher: fileWatcher)
    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    viewModel.startMonitoring(session: session)

    fileWatcher.send(sessionId: session.id, state: SessionMonitorState(status: .thinking))
    try await waitUntil { viewModel.sessionStatus(for: session.id) == .thinking }

    var referencesInvalidated = false
    withObservationTracking {
      _ = viewModel.sessionPullRequestReferences
    } onChange: {
      referencesInvalidated = true
    }

    fileWatcher.send(
      sessionId: session.id,
      state: SessionMonitorState(
        status: .thinking,
        detectedResourceLinks: [ResourceLink(url: "https://github.com/owner/repo/pull/12")]
      )
    )
    try await waitUntil { !viewModel.pullRequestReferences(for: session.id).isEmpty }

    #expect(referencesInvalidated)
    #expect(viewModel.pullRequestReferences(for: session.id).map(\.number) == [12])
  }

  @Test("Stopping monitoring clears both projections")
  @MainActor
  func stopMonitoringClearsProjections() async throws {
    let fileWatcher = ProjectionFileWatcher()
    let viewModel = makeProjectionViewModel(fileWatcher: fileWatcher)
    let session = CLISession(id: "session-1", projectPath: "/tmp/project")
    viewModel.startMonitoring(session: session)

    fileWatcher.send(
      sessionId: session.id,
      state: SessionMonitorState(
        status: .thinking,
        detectedResourceLinks: [ResourceLink(url: "https://github.com/owner/repo/pull/7")]
      )
    )
    try await waitUntil { viewModel.sessionStatus(for: session.id) != nil }

    viewModel.stopMonitoring(session: session)

    #expect(viewModel.sessionStatus(for: session.id) == nil)
    #expect(viewModel.pullRequestReferences(for: session.id).isEmpty)
  }

  @Test("monitoredCLISessions mirrors monitoredSessions without carrying state")
  @MainActor
  func monitoredCLISessionsMirrorsMonitoredSessions() {
    let fileWatcher = ProjectionFileWatcher()
    let viewModel = makeProjectionViewModel(fileWatcher: fileWatcher)
    let first = CLISession(id: "session-1", projectPath: "/tmp/project-a")
    let second = CLISession(id: "session-2", projectPath: "/tmp/project-b")

    viewModel.startMonitoring(session: first)
    viewModel.startMonitoring(session: second)

    #expect(viewModel.monitoredCLISessions.map(\.id) == viewModel.monitoredSessions.map(\.session.id))

    viewModel.stopMonitoring(session: first)

    #expect(viewModel.monitoredCLISessions.map(\.id) == viewModel.monitoredSessions.map(\.session.id))
  }
}
