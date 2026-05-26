import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Worktree settings inventory")
struct WorktreeSettingsInventoryTests {
  @Test("Snapshot keeps side panel module order and includes modules without worktrees")
  func snapshotKeepsModuleOrder() {
    let agentHub = SelectedRepository(path: "/tmp/AgentHub")
    let xcodeTrace = SelectedRepository(path: "/tmp/XcodeTraceMCP")
    let agentHubPage = SelectedRepository(path: "/tmp/AgentHubPage")

    let snapshot = WorktreeSettingsInventoryBuilder.snapshot(
      claudeRepositories: [agentHub, xcodeTrace, agentHubPage],
      codexRepositories: [],
      claudeMonitoredSessions: [],
      codexMonitoredSessions: []
    )

    #expect(snapshot.modules.map(\.name) == ["AgentHubPage", "XcodeTraceMCP", "AgentHub"])
    #expect(snapshot.modules.map(\.worktrees.count) == [0, 0, 0])
  }

  @Test("Snapshot lists real worktrees once across providers and counts monitored sessions")
  func snapshotDeduplicatesProviderWorktrees() throws {
    let claudeSession = session(
      "claude-session",
      path: "/tmp/AgentHub-feature",
      isActive: true
    )
    let codexSession = session(
      "codex-session",
      path: "/tmp/AgentHub-feature/app"
    )
    let claudeRepository = SelectedRepository(
      path: "/tmp/AgentHub",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/AgentHub", isWorktree: false),
        WorktreeBranch(
          name: "feature/settings",
          path: "/tmp/AgentHub-feature",
          isWorktree: true,
          sessions: [claudeSession]
        ),
      ]
    )
    let codexRepository = SelectedRepository(
      path: "/tmp/AgentHub",
      worktrees: [
        WorktreeBranch(
          name: "feature/settings",
          path: "/tmp/AgentHub-feature/",
          isWorktree: true,
          sessions: [codexSession]
        ),
      ]
    )

    let snapshot = WorktreeSettingsInventoryBuilder.snapshot(
      claudeRepositories: [claudeRepository],
      codexRepositories: [codexRepository],
      claudeMonitoredSessions: [claudeSession],
      codexMonitoredSessions: [codexSession]
    )

    let module = try #require(snapshot.modules.first)
    let worktree = try #require(module.worktrees.first)

    #expect(module.worktrees.count == 1)
    #expect(worktree.path == "/tmp/AgentHub-feature")
    #expect(worktree.providerKinds == [.claude, .codex])
    #expect(worktree.deletionProviderKind == .claude)
    #expect(worktree.monitoredSessionCount == 2)
    #expect(worktree.activeMonitoredSessionCount == 1)
    #expect(worktree.historicalSessionCount == 2)
  }
}

@Suite("Worktree settings deletion helpers")
@MainActor
struct WorktreeSettingsDeletionHelperTests {
  @Test("Archive monitored sessions under worktree keeps other sessions")
  func archiveMonitoredSessionsUnderWorktree() {
    let viewModel = makeDeletionViewModel()
    let worktreeSession = session("worktree-session", path: "/tmp/AgentHub-feature")
    let nestedWorktreeSession = session("nested-session", path: "/tmp/AgentHub-feature/app")
    let otherSession = session("other-session", path: "/tmp/AgentHub-other")

    viewModel.startMonitoring(session: worktreeSession)
    viewModel.startMonitoring(session: nestedWorktreeSession)
    viewModel.startMonitoring(session: otherSession)

    viewModel.archiveMonitoredSessions(inWorktreePath: "/tmp/AgentHub-feature")

    #expect(viewModel.monitoredSessionIds == Set(["other-session"]))
  }

  @Test("Delete worktree reports success and records removal")
  func deleteWorktreeReportsSuccess() async throws {
    let remover = RecordingWorktreeRemovalService()
    let viewModel = makeDeletionViewModel(remover: remover)
    let worktreePath = try temporaryDirectory(name: "delete-success")
    let worktree = WorktreeBranch(name: "feature", path: worktreePath, isWorktree: true)

    let succeeded = await viewModel.deleteWorktree(worktree)

    #expect(succeeded)
    #expect(viewModel.worktreeDeletionError == nil)
    #expect(viewModel.deletingWorktreePath == nil)
    #expect(await remover.removedWorktreePaths() == [worktreePath])
  }

  @Test("Delete worktree failure keeps monitored sessions")
  func deleteWorktreeFailureKeepsMonitoredSessions() async throws {
    let remover = RecordingWorktreeRemovalService(error: TestDeletionError.failed)
    let viewModel = makeDeletionViewModel(remover: remover)
    let worktreePath = try temporaryDirectory(name: "delete-failure")
    let worktree = WorktreeBranch(name: "feature", path: worktreePath, isWorktree: true)
    let monitoredSession = session("session-1", path: worktreePath)
    viewModel.startMonitoring(session: monitoredSession)

    let succeeded = await viewModel.deleteWorktree(worktree)

    #expect(!succeeded)
    #expect(viewModel.worktreeDeletionError?.worktree.path == worktreePath)
    #expect(viewModel.monitoredSessionIds == Set(["session-1"]))
  }
}

private func session(_ id: String, path: String, isActive: Bool = false) -> CLISession {
  CLISession(
    id: id,
    projectPath: path,
    branchName: "feature",
    isWorktree: true,
    isActive: isActive,
    sessionFilePath: "/tmp/\(id).jsonl"
  )
}

@MainActor
private func makeDeletionViewModel(
  remover: RecordingWorktreeRemovalService = RecordingWorktreeRemovalService()
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: WorktreeDeletionMonitorService(),
    fileWatcher: WorktreeDeletionFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService(),
    worktreeRemovalService: remover
  )
}

private final class WorktreeDeletionMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
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

private final class WorktreeDeletionFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
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

private actor RecordingWorktreeRemovalService: GitWorktreeRemovalServiceProtocol {
  private let error: Error?
  private var paths: [String] = []

  init(error: Error? = nil) {
    self.error = error
  }

  func removeWorktree(at worktreePath: String, force: Bool) async throws {
    if let error { throw error }
    paths.append(worktreePath)
  }

  func removeWorktree(at worktreePath: String, relativeTo parentRepoPath: String, force: Bool) async throws {
    if let error { throw error }
    paths.append(worktreePath)
  }

  nonisolated func checkIfOrphaned(at worktreePath: String) -> (isOrphaned: Bool, parentRepoPath: String?)? {
    nil
  }

  func removeOrphanedWorktree(at worktreePath: String, parentRepoPath: String) async throws {
    if let error { throw error }
    paths.append(worktreePath)
  }

  func removedWorktreePaths() -> [String] {
    paths
  }
}

private enum TestDeletionError: Error {
  case failed
}

private func temporaryDirectory(name: String) throws -> String {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentHubWorktreeSettingsTests")
    .appendingPathComponent("\(name)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url.path
}
