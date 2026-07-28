import Combine
import Foundation
import Testing

@testable import AgentHubCore

private actor PinnedRetentionStubMonitorService: SessionMonitorServiceProtocol {
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

private actor PinnedRetentionStubFileWatcher: SessionFileWatcherProtocol {
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

@Suite("Pinned session retention")
@MainActor
struct PinnedSessionRetentionTests {

  private func makeStore() throws -> SessionMetadataStore {
    let dbPath = FileManager.default.temporaryDirectory
      .appending(path: "pinned_retention_\(UUID().uuidString).sqlite")
      .path
    return try SessionMetadataStore(path: dbPath)
  }

  private func makeViewModel(
    monitorService: PinnedRetentionStubMonitorService,
    store: SessionMetadataStore
  ) -> CLISessionsViewModel {
    CLISessionsViewModel(
      monitorService: monitorService,
      fileWatcher: PinnedRetentionStubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      metadataStore: store,
      approvalNotificationService: NoOpApprovalNotificationService()
    )
  }

  @Test("Pinned session in a deleted worktree survives launch restore; unpinned one is dropped")
  func pinnedSessionInDeletedWorktreeSurvivesRestore() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("PinnedRetention-\(UUID().uuidString)")
    let repoDir = base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let deletedWorktreePath = base.appendingPathComponent("repo-deleted").path

    let store = try makeStore()
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: [repoDir.path],
        monitoredSessionIds: ["pinned-gone", "unpinned-gone"],
        ownedWorktreePaths: []
      ),
      for: .claude
    )
    try await store.setPinned(true, for: "pinned-gone")

    let monitorService = PinnedRetentionStubMonitorService(
      skeletonRepositories: [SelectedRepository(path: repoDir.path)],
      loadableSessions: [
        CLISession(
          id: "pinned-gone",
          projectPath: deletedWorktreePath,
          branchName: "kept",
          isWorktree: true,
          isActive: false,
          sessionFilePath: "/tmp/pinned-gone.jsonl"
        ),
        CLISession(
          id: "unpinned-gone",
          projectPath: deletedWorktreePath,
          branchName: "dropped",
          isWorktree: true,
          isActive: false,
          sessionFilePath: "/tmp/unpinned-gone.jsonl"
        ),
      ]
    )

    let viewModel = makeViewModel(monitorService: monitorService, store: store)

    var persisted: [String] = ["unpinned-gone"]
    for _ in 0..<400 where persisted.contains("unpinned-gone") || !persisted.contains("pinned-gone") {
      persisted = store.getWorkspaceStateSync(for: .claude).monitoredSessionIds
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(persisted.contains("pinned-gone"))
    #expect(!persisted.contains("unpinned-gone"))
    #expect(viewModel.isMonitoring(sessionId: "pinned-gone"))
    #expect(!viewModel.isMonitoring(sessionId: "unpinned-gone"))
  }

  @Test("Pinned session missing from the persisted monitored set is re-monitored at launch")
  func pinnedSessionMissingFromMonitoredSetIsRestored() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("PinnedRetention-\(UUID().uuidString)")
    let repoDir = base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let store = try makeStore()
    try await store.saveWorkspaceState(
      SessionWorkspaceState(
        selectedRepositoryPaths: [repoDir.path],
        monitoredSessionIds: [],
        ownedWorktreePaths: []
      ),
      for: .claude
    )
    try await store.setPinned(true, for: "lost-pin")

    let monitorService = PinnedRetentionStubMonitorService(
      skeletonRepositories: [SelectedRepository(path: repoDir.path)],
      loadableSessions: [
        CLISession(
          id: "lost-pin",
          projectPath: repoDir.path,
          branchName: "main",
          isWorktree: false,
          isActive: false,
          sessionFilePath: "/tmp/lost-pin.jsonl"
        ),
      ]
    )

    let viewModel = makeViewModel(monitorService: monitorService, store: store)

    var persisted: [String] = []
    for _ in 0..<400 where !persisted.contains("lost-pin") {
      persisted = store.getWorkspaceStateSync(for: .claude).monitoredSessionIds
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(persisted.contains("lost-pin"))
    #expect(viewModel.isMonitoring(sessionId: "lost-pin"))
  }

  @Test("Worktree archive sweep skips pinned sessions")
  func archiveSweepSkipsPinnedSessions() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("PinnedRetention-\(UUID().uuidString)")
    let worktreeDir = base.appendingPathComponent("repo-feature")
    try FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let store = try makeStore()
    try await store.setPinned(true, for: "pinned-session")

    let monitorService = PinnedRetentionStubMonitorService(
      skeletonRepositories: [],
      loadableSessions: []
    )
    let viewModel = makeViewModel(monitorService: monitorService, store: store)

    let pinnedSession = CLISession(
      id: "pinned-session",
      projectPath: worktreeDir.path,
      branchName: "feature",
      isWorktree: true,
      isActive: false,
      sessionFilePath: "/tmp/pinned-session.jsonl"
    )
    let unpinnedSession = CLISession(
      id: "unpinned-session",
      projectPath: worktreeDir.path,
      branchName: "feature",
      isWorktree: true,
      isActive: false,
      sessionFilePath: "/tmp/unpinned-session.jsonl"
    )
    viewModel.startMonitoring(session: pinnedSession)
    viewModel.startMonitoring(session: unpinnedSession)

    viewModel.archiveMonitoredSessions(inWorktreePath: worktreeDir.path)

    #expect(viewModel.isMonitoring(sessionId: "pinned-session"))
    #expect(!viewModel.isMonitoring(sessionId: "unpinned-session"))
  }

  @Test("Explicitly archiving a pinned session clears its pin")
  func explicitStopMonitoringUnpins() async throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("PinnedRetention-\(UUID().uuidString)")
    let repoDir = base.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let store = try makeStore()
    try await store.setPinned(true, for: "pinned-session")

    let monitorService = PinnedRetentionStubMonitorService(
      skeletonRepositories: [],
      loadableSessions: []
    )
    let viewModel = makeViewModel(monitorService: monitorService, store: store)
    #expect(viewModel.pinnedSessionIds.contains("pinned-session"))

    let session = CLISession(
      id: "pinned-session",
      projectPath: repoDir.path,
      branchName: "main",
      isWorktree: false,
      isActive: false,
      sessionFilePath: "/tmp/pinned-session.jsonl"
    )
    viewModel.startMonitoring(session: session)

    viewModel.stopMonitoring(sessionId: "pinned-session")

    #expect(!viewModel.isMonitoring(sessionId: "pinned-session"))
    #expect(!viewModel.pinnedSessionIds.contains("pinned-session"))

    var storedPins: Set<String> = ["pinned-session"]
    for _ in 0..<400 where storedPins.contains("pinned-session") {
      storedPins = try await store.getPinnedSessionIds()
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!storedPins.contains("pinned-session"))
  }
}
