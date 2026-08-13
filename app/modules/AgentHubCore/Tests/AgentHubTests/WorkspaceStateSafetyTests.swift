import Combine
import Foundation
import Testing

@testable import AgentHubCore

// Guards the two safety layers added after the 2026-08-13 incident where a
// test run sharing the production database caused the app to overwrite the
// user's workspace state (tracked projects + monitored sessions) with a
// near-empty list:
//
// 1. Test processes are sandboxed away from the real Application Support dir.
// 2. Workspace-state saves are disabled until the persisted state has been
//    read successfully once — a failed read must never masquerade as "empty"
//    and then get saved back over good data.

@Suite("Application Support test sandbox")
struct ApplicationSupportSandboxTests {

  @Test("Test processes resolve to a temp sandbox, never the real Application Support")
  func testProcessResolvesToSandbox() {
    #expect(AgentHubApplicationSupport.isTestProcess)
    let base = AgentHubApplicationSupport.baseDirectoryURL.path
    #expect(base.contains("AgentHubTestSandbox-"))
    #expect(!base.contains("/Library/Application Support/AgentHub"))
    #expect(ClaudeHookPaths.appSupportBaseURL.path == base)
  }

  @Test("Default-initialized metadata store lives in the sandbox")
  func defaultStoreLivesInSandbox() throws {
    _ = try SessionMetadataStore()
    let sandboxDB = AgentHubApplicationSupport.baseDirectoryURL
      .appendingPathComponent("session_metadata.sqlite")
    #expect(FileManager.default.fileExists(atPath: sandboxDB.path))
  }
}

@Suite("Workspace state save gate")
@MainActor
struct WorkspaceStateSaveGateTests {

  @Test("A failed read disables saves so persisted state survives the run")
  func readFailureKeepsPersistedStateIntact() async throws {
    let store = try await makeSeededStore(
      repositoryPaths: ["/tmp/wsstate-a", "/tmp/wsstate-b"],
      monitoredSessionIds: ["persisted-session"]
    )
    let viewModel = makeSafetyFixtureViewModel(store: store)
    viewModel.workspaceStateReadOverride = { _ in
      throw WorkspaceStateSafetyTestError.simulatedReadFailure
    }

    // Let the restore retries run out, then poke every save entry point a
    // clobbering launch would hit.
    try await Task.sleep(for: .milliseconds(1500))
    await viewModel.importMonitoredSessions([
      CLISession(id: "new-session", projectPath: "/tmp/wsstate-a", branchName: "main")
    ])
    try await Task.sleep(for: .milliseconds(500))

    let persisted = try store.readWorkspaceState(for: .claude)
    #expect(persisted.selectedRepositoryPaths == ["/tmp/wsstate-a", "/tmp/wsstate-b"])
    #expect(persisted.monitoredSessionIds == ["persisted-session"])
  }

  @Test("A successful read enables saves and preserves restored state")
  func successfulReadAllowsSaves() async throws {
    let store = try await makeSeededStore(
      repositoryPaths: ["/tmp/wsstate-a"],
      monitoredSessionIds: []
    )
    let viewModel = makeSafetyFixtureViewModel(store: store)

    await viewModel.importMonitoredSessions([
      CLISession(id: "imported-session", projectPath: "/tmp/wsstate-a", branchName: "main")
    ])

    try await waitUntil {
      (try? store.readWorkspaceState(for: .claude))?.monitoredSessionIds.contains("imported-session") == true
    }
    let persisted = try store.readWorkspaceState(for: .claude)
    #expect(persisted.selectedRepositoryPaths.contains("/tmp/wsstate-a"))
  }
}

// MARK: - Fixture

private enum WorkspaceStateSafetyTestError: Error {
  case simulatedReadFailure
}

private func makeSeededStore(
  repositoryPaths: [String],
  monitoredSessionIds: [String]
) async throws -> SessionMetadataStore {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("WorkspaceStateSafetyTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let store = try SessionMetadataStore(path: dir.appendingPathComponent("db.sqlite").path)

  let state = SessionWorkspaceState(
    selectedRepositoryPaths: repositoryPaths,
    monitoredSessionIds: monitoredSessionIds,
    expansionState: [:]
  )
  try await store.saveWorkspaceState(state, for: .claude)
  return store
}

@MainActor
private func makeSafetyFixtureViewModel(store: SessionMetadataStore) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: WorkspaceSafetyMonitorService(),
    fileWatcher: WorkspaceSafetyFileWatcher(),
    searchService: nil,
    cliConfiguration: .claudeDefault,
    providerKind: .claude,
    metadataStore: store,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
}

@MainActor
private func waitUntil(
  _ condition: @escaping () -> Bool,
  timeoutAttempts: Int = 250
) async throws {
  for _ in 0..<timeoutAttempts {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition())
}

private final class WorkspaceSafetyMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = CurrentValueSubject<[SelectedRepository], Never>([])
  private var repositories: [SelectedRepository] = []

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? {
    guard !repositories.contains(where: { $0.path == path }) else { return nil }
    let repository = SelectedRepository(path: path)
    repositories.append(repository)
    subject.send(repositories)
    return repository
  }

  func removeRepository(_ path: String) async {
    repositories.removeAll { $0.path == path }
    subject.send(repositories)
  }

  func getSelectedRepositories() async -> [SelectedRepository] { repositories }

  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    self.repositories = repositories
    subject.send(repositories)
  }

  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class WorkspaceSafetyFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
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
