import Combine
import Foundation
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Agent workspace session coordinator")
struct AgentWorkspaceSessionCoordinatorTests {
  @Test(
    "Detected workspace sessions persist through the normal provider restore flow",
    arguments: SessionProviderKind.allCases
  )
  func detectedSessionPersistsForRelaunch(provider: SessionProviderKind) async throws {
    let store = try SessionMetadataStore(path: temporaryCoordinatorDatabasePath())
    let session = workspaceSession(provider: provider)
    let claudeMonitor = WorkspaceCoordinatorMonitorSpy(
      sessionsByID: provider == .claude ? [session.id: session] : [:]
    )
    let codexMonitor = WorkspaceCoordinatorMonitorSpy(
      sessionsByID: provider == .codex ? [session.id: session] : [:]
    )
    let claudeWatcher = WorkspaceCoordinatorWatcherSpy()
    let codexWatcher = WorkspaceCoordinatorWatcherSpy()
    let claudeViewModel = makeCoordinatorViewModel(
      provider: .claude,
      monitor: claudeMonitor,
      watcher: claudeWatcher,
      store: store
    )
    let codexViewModel = makeCoordinatorViewModel(
      provider: .codex,
      monitor: codexMonitor,
      watcher: codexWatcher,
      store: store
    )
    let coordinator = AgentWorkspaceSessionCoordinator(
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel
    )

    await coordinator.monitorDetectedSession(
      AccessorySessionDetectionResult(
        provider: provider,
        sessionId: session.id,
        projectPath: session.projectPath,
        branchName: session.branchName,
        sessionFilePath: try #require(session.sessionFilePath)
      )
    )

    await waitForCoordinatorCondition {
      let state = store.getWorkspaceStateSync(for: provider)
      return state.selectedRepositoryPaths == [session.projectPath]
        && state.monitoredSessionIds == [session.id]
    }

    let relaunchMonitor = WorkspaceCoordinatorMonitorSpy(sessionsByID: [session.id: session])
    let relaunchWatcher = WorkspaceCoordinatorWatcherSpy()
    let relaunchedViewModel = makeCoordinatorViewModel(
      provider: provider,
      monitor: relaunchMonitor,
      watcher: relaunchWatcher,
      store: store
    )

    await waitForCoordinatorCondition {
      relaunchedViewModel.selectedRepositories.map(\.path) == [session.projectPath]
        && relaunchedViewModel.monitoredSessionIds == [session.id]
        && relaunchedViewModel.monitoredSessions.map(\.session.id) == [session.id]
    }
  }

  @Test("Persisted workspace references restore idempotently without mounting terminals")
  func persistedReferencesRestoreIdempotently() async throws {
    let store = try SessionMetadataStore(path: temporaryCoordinatorDatabasePath())
    let session = workspaceSession(provider: .claude)
    let claudeMonitor = WorkspaceCoordinatorMonitorSpy(sessionsByID: [session.id: session])
    let claudeWatcher = WorkspaceCoordinatorWatcherSpy()
    let claudeViewModel = makeCoordinatorViewModel(
      provider: .claude,
      monitor: claudeMonitor,
      watcher: claudeWatcher,
      store: store
    )
    let coordinator = AgentWorkspaceSessionCoordinator(
      claudeViewModel: claudeViewModel,
      codexViewModel: makeCoordinatorViewModel(
        provider: .codex,
        monitor: WorkspaceCoordinatorMonitorSpy(),
        watcher: WorkspaceCoordinatorWatcherSpy(),
        store: store
      )
    )
    let reference = AgentWorkspaceSessionReference(
      provider: .claude,
      sessionId: session.id,
      projectPath: session.projectPath
    )

    await coordinator.restorePersistedSessions([reference, reference])
    await coordinator.restorePersistedSessions([reference])

    await waitForCoordinatorCondition {
      claudeViewModel.monitoredSessionIds == [session.id]
        && store.getWorkspaceStateSync(for: .claude).monitoredSessionIds == [session.id]
    }
    #expect(claudeViewModel.monitoredSessions.map(\.session.id) == [session.id])
    #expect(await claudeWatcher.startedSessionIDs() == [session.id])
    #expect(store.getWorkspaceStateSync(for: .claude).monitoredSessionIds == [session.id])
  }

  @Test("Persisted workspace references are visible while session files are loading")
  func persistedReferenceIsVisibleDuringTargetedLoad() async throws {
    let store = try SessionMetadataStore(path: temporaryCoordinatorDatabasePath())
    let monitor = WorkspaceCoordinatorMonitorSpy(loadDelay: .seconds(5))
    let viewModel = makeCoordinatorViewModel(
      provider: .claude,
      monitor: monitor,
      watcher: WorkspaceCoordinatorWatcherSpy(),
      store: store
    )
    let coordinator = AgentWorkspaceSessionCoordinator(
      claudeViewModel: viewModel,
      codexViewModel: makeCoordinatorViewModel(
        provider: .codex,
        monitor: WorkspaceCoordinatorMonitorSpy(),
        watcher: WorkspaceCoordinatorWatcherSpy(),
        store: store
      )
    )
    let reference = AgentWorkspaceSessionReference(
      provider: .claude,
      sessionId: "loading-session",
      projectPath: "/tmp/project"
    )

    let restoreTask = Task {
      await coordinator.restorePersistedSessions([reference])
    }

    for _ in 0..<200 where await monitor.loadedSessionRequests().isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await monitor.loadedSessionRequests() == [Set(["loading-session"])])
    #expect(viewModel.monitoredSessions.map(\.session.id) == ["loading-session"])
    #expect(viewModel.monitoredSessions.first?.session.projectPath == "/tmp/project")

    restoreTask.cancel()
    await restoreTask.value
  }

  @Test("Missing session files remain visible and retained for a later workspace reconciliation")
  func missingSessionRemainsRetained() async throws {
    let store = try SessionMetadataStore(path: temporaryCoordinatorDatabasePath())
    let monitor = WorkspaceCoordinatorMonitorSpy()
    let viewModel = makeCoordinatorViewModel(
      provider: .codex,
      monitor: monitor,
      watcher: WorkspaceCoordinatorWatcherSpy(),
      store: store
    )
    let coordinator = AgentWorkspaceSessionCoordinator(
      claudeViewModel: makeCoordinatorViewModel(
        provider: .claude,
        monitor: WorkspaceCoordinatorMonitorSpy(),
        watcher: WorkspaceCoordinatorWatcherSpy(),
        store: store
      ),
      codexViewModel: viewModel
    )

    await coordinator.restorePersistedSessions([
      AgentWorkspaceSessionReference(
        provider: .codex,
        sessionId: "missing-session",
        projectPath: "/tmp/project"
      )
    ])

    await waitForCoordinatorCondition {
      let state = store.getWorkspaceStateSync(for: .codex)
      return state.selectedRepositoryPaths == ["/tmp/project"]
        && state.monitoredSessionIds == ["missing-session"]
    }
    #expect(viewModel.isMonitoring(sessionId: "missing-session"))
    #expect(viewModel.monitoredSessions.map(\.session.id) == ["missing-session"])
    #expect(viewModel.monitoredSessions.first?.session.projectPath == "/tmp/project")
    #expect(viewModel.monitoredSessions.first?.session.sessionFilePath == nil)
    #expect(await monitor.loadedSessionRequests() == [Set(["missing-session"])])
  }
}

@MainActor
private func makeCoordinatorViewModel(
  provider: SessionProviderKind,
  monitor: WorkspaceCoordinatorMonitorSpy,
  watcher: WorkspaceCoordinatorWatcherSpy,
  store: SessionMetadataStore
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: monitor,
    fileWatcher: watcher,
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(
      command: provider == .claude ? "claude" : "codex",
      mode: provider == .claude ? .claude : .codex
    ),
    providerKind: provider,
    metadataStore: store,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
}

private func workspaceSession(provider: SessionProviderKind) -> CLISession {
  CLISession(
    id: "\(provider.rawValue.lowercased())-session",
    projectPath: "/tmp/project",
    branchName: "main",
    lastActivityAt: .now,
    isActive: true,
    sessionFilePath: "/tmp/\(provider.rawValue.lowercased())-session.jsonl"
  )
}

private actor WorkspaceCoordinatorMonitorSpy: SessionMonitorServiceProtocol {
  nonisolated(unsafe) private let subject = CurrentValueSubject<[SelectedRepository], Never>([])

  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  private let sessionsByID: [String: CLISession]
  private let loadDelay: Duration?
  private var repositories: [SelectedRepository] = []
  private var loadRequests: [Set<String>] = []

  init(
    sessionsByID: [String: CLISession] = [:],
    loadDelay: Duration? = nil
  ) {
    self.sessionsByID = sessionsByID
    self.loadDelay = loadDelay
  }

  func addRepository(_ path: String) async -> SelectedRepository? {
    guard !repositories.contains(where: { $0.path == path }) else { return nil }
    let sessions = sessionsByID.values.filter {
      $0.projectPath == path || $0.projectPath.hasPrefix(path + "/")
    }
    let repository = SelectedRepository(
      path: path,
      worktrees: [
        WorktreeBranch(
          name: "main",
          path: path,
          isWorktree: false,
          sessions: sessions
        )
      ]
    )
    repositories.append(repository)
    subject.send(repositories)
    return repository
  }

  func loadSessions(ids: Set<String>) async -> [CLISession] {
    loadRequests.append(ids)
    if let loadDelay {
      try? await Task.sleep(for: loadDelay)
    }
    return ids.compactMap { sessionsByID[$0] }
  }

  func removeRepository(_ path: String) async {
    repositories.removeAll { $0.path == path }
    subject.send(repositories)
  }

  func getSelectedRepositories() async -> [SelectedRepository] {
    repositories
  }

  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    self.repositories = repositories
    subject.send(repositories)
  }

  func refreshSessions(skipWorktreeRedetection: Bool) async {
    subject.send(repositories)
  }

  func loadedSessionRequests() -> [Set<String>] {
    loadRequests
  }
}

private actor WorkspaceCoordinatorWatcherSpy: SessionFileWatcherProtocol {
  nonisolated(unsafe) private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()

  nonisolated var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> {
    subject.eraseToAnyPublisher()
  }

  private var started: [String] = []

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {
    started.append(sessionId)
  }

  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}

  func startedSessionIDs() -> [String] {
    started
  }
}

@MainActor
private func waitForCoordinatorCondition(
  timeout: Duration = .seconds(2),
  condition: @escaping @MainActor () -> Bool
) async {
  let start = ContinuousClock.now
  while !condition(), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition())
}

private func temporaryCoordinatorDatabasePath() -> String {
  FileManager.default.temporaryDirectory
    .appending(path: "agent_workspace_coordinator_\(UUID().uuidString).sqlite")
    .path
}
