import Combine
import Foundation
import Testing

@testable import AgentHubCore

private actor RetentionStubMonitorService: SessionMonitorServiceProtocol {
  private let skeletonRepositories: [SelectedRepository]
  private let loadableSessions: [CLISession]

  init(skeletonRepositories: [SelectedRepository], loadableSessions: [CLISession]) {
    self.skeletonRepositories = skeletonRepositories
    self.loadableSessions = loadableSessions
  }

  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { skeletonRepositories }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}

  func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository] {
    skeletonRepositories
  }

  func loadSessions(ids: Set<String>) async -> [CLISession] {
    loadableSessions.filter { ids.contains($0.id) }
  }
}

private actor RetentionStubFileWatcher: SessionFileWatcherProtocol {
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

@Suite("Launch restore session retention")
@MainActor
struct LaunchRestoreSessionRetentionTests {
  @Test("Keeps a rejected worktree session whose directory still exists; drops one confirmed gone")
  func keepsTransientlyUnrestorableWorktreeSession() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("RestoreRetention-\(UUID().uuidString)")
    let repoDir = base.appendingPathComponent("repo")
    let worktreeDir = base.appendingPathComponent("repo-feature")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let deletedWorktreePath = base.appendingPathComponent("repo-deleted").path

    let dbPath = FileManager.default.temporaryDirectory
      .appending(path: "restore_retention_\(UUID().uuidString).sqlite")
      .path
    let store = try SessionMetadataStore(path: dbPath)
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: [repoDir.path],
        monitoredSessionIds: ["gone-session", "wt-session"],
        ownedWorktreePaths: []
      ),
      for: .claude
    )

    let monitorService = RetentionStubMonitorService(
      skeletonRepositories: [SelectedRepository(path: repoDir.path)],
      loadableSessions: [
        CLISession(
          id: "wt-session",
          projectPath: worktreeDir.path,
          branchName: "feature",
          isWorktree: true,
          isActive: false,
          sessionFilePath: "/tmp/wt-session.jsonl"
        ),
        CLISession(
          id: "gone-session",
          projectPath: deletedWorktreePath,
          branchName: "deleted",
          isWorktree: true,
          isActive: false,
          sessionFilePath: "/tmp/gone-session.jsonl"
        ),
      ]
    )

    let viewModel = CLISessionsViewModel(
      monitorService: monitorService,
      fileWatcher: RetentionStubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    var persisted: [String] = ["gone-session"]
    for _ in 0..<400 where persisted.contains("gone-session") {
      persisted = store.getWorkspaceStateSync(for: .claude).monitoredSessionIds
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(persisted.contains("wt-session"))
    #expect(!persisted.contains("gone-session"))
    #expect(!viewModel.isMonitoring(sessionId: "wt-session"))
  }
}
