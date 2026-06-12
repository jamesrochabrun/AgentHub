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
    #expect(worktree.isFocusedInAgentHub)
    #expect(worktree.monitoredSessionCount == 2)
    #expect(worktree.activeMonitoredSessionCount == 1)
    #expect(worktree.historicalSessionCount == 2)
  }

  @Test("Snapshot includes external discovered worktrees")
  func snapshotIncludesExternalDiscoveredWorktrees() throws {
    let repository = SelectedRepository(
      path: "/tmp/AgentHub",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/AgentHub", isWorktree: false),
      ]
    )

    let snapshot = WorktreeSettingsInventoryBuilder.snapshot(
      claudeRepositories: [repository],
      codexRepositories: [],
      claudeMonitoredSessions: [],
      codexMonitoredSessions: [],
      discoveredWorktreesByRepositoryPath: [
        "/tmp/AgentHub": [
          GitWorktreeInventoryItem(
            path: "/tmp/AgentHub",
            branchName: "main",
            isWorktree: false,
            mainRepoPath: nil
          ),
          GitWorktreeInventoryItem(
            path: "/tmp/AgentHub-external",
            branchName: "feature/external",
            isWorktree: true,
            mainRepoPath: "/tmp/AgentHub"
          ),
        ]
      ]
    )

    let module = try #require(snapshot.modules.first)
    let worktree = try #require(module.worktrees.first)

    #expect(module.worktrees.count == 1)
    #expect(worktree.branchName == "feature/external")
    #expect(worktree.path == "/tmp/AgentHub-external")
    #expect(worktree.parentModulePath == "/tmp/AgentHub")
    #expect(worktree.providerKinds.isEmpty)
    #expect(!worktree.isFocusedInAgentHub)
    #expect(worktree.monitoredSessionCount == 0)
    #expect(worktree.historicalSessionCount == 0)
  }

  @Test("Snapshot deduplicates discovered and focused worktrees")
  func snapshotDeduplicatesDiscoveredAndFocusedWorktrees() throws {
    let repository = SelectedRepository(
      path: "/tmp/AgentHub",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/AgentHub", isWorktree: false),
        WorktreeBranch(name: "feature/focused", path: "/tmp/AgentHub-focused", isWorktree: true),
      ]
    )

    let snapshot = WorktreeSettingsInventoryBuilder.snapshot(
      claudeRepositories: [repository],
      codexRepositories: [],
      claudeMonitoredSessions: [],
      codexMonitoredSessions: [],
      discoveredWorktreesByRepositoryPath: [
        "/tmp/AgentHub": [
          GitWorktreeInventoryItem(
            path: "/tmp/AgentHub-focused/",
            branchName: "feature/focused",
            isWorktree: true,
            mainRepoPath: "/tmp/AgentHub"
          )
        ]
      ]
    )

    let module = try #require(snapshot.modules.first)
    let worktree = try #require(module.worktrees.first)

    #expect(module.worktrees.count == 1)
    #expect(worktree.path == "/tmp/AgentHub-focused")
    #expect(worktree.providerKinds == [.claude])
    #expect(worktree.isFocusedInAgentHub)
  }

  @Test("Snapshot counts only sessions attached to the focused worktree row")
  func snapshotIgnoresStalePathMatchedBackups() throws {
    let displayedSession = session("displayed-session", path: "/tmp/AgentHub-feature")
    let staleSession = session("stale-session", path: "/tmp/AgentHub-feature")
    let nestedStaleSession = session("nested-stale-session", path: "/tmp/AgentHub-feature/app")
    let repository = SelectedRepository(
      path: "/tmp/AgentHub",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/AgentHub", isWorktree: false),
        WorktreeBranch(
          name: "feature/focused",
          path: "/tmp/AgentHub-feature",
          isWorktree: true,
          sessions: [displayedSession]
        ),
      ]
    )

    let snapshot = WorktreeSettingsInventoryBuilder.snapshot(
      claudeRepositories: [repository],
      codexRepositories: [],
      claudeMonitoredSessions: [displayedSession, staleSession, nestedStaleSession],
      codexMonitoredSessions: []
    )

    let worktree = try #require(snapshot.modules.first?.worktrees.first)
    #expect(worktree.monitoredSessionCount == 1)
    #expect(worktree.historicalSessionCount == 1)
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

  @Test("Delete worktree for nested session removes the worktree root", .disabled("headless-quarantine: symlink/async path matching; see TestQuarantine.md"))
  func deleteWorktreeForNestedSessionRemovesWorktreeRoot() async throws {
    let remover = RecordingWorktreeRemovalService()
    let repoPath = try temporaryDirectory(name: "delete-nested-repo")
    let worktreePath = try temporaryDirectory(name: "delete-nested-worktree")
    let nestedSession = session("nested-session", path: worktreePath + "/app")
    let rootSession = session("root-session", path: worktreePath)
    let repository = SelectedRepository(
      path: repoPath,
      worktrees: [
        WorktreeBranch(name: "main", path: repoPath, isWorktree: false),
        WorktreeBranch(
          name: "feature",
          path: worktreePath,
          isWorktree: true,
          sessions: [nestedSession, rootSession]
        ),
      ]
    )
    let monitor = WorktreeDeletionMonitorService(repositories: [repository])
    let viewModel = makeDeletionViewModel(remover: remover, monitor: monitor)
    await waitForDeletionViewModel {
      !viewModel.selectedRepositories.isEmpty
    }
    viewModel.startMonitoring(session: nestedSession)
    viewModel.startMonitoring(session: rootSession)

    let succeeded = await viewModel.deleteWorktreeForSession(nestedSession)

    #expect(succeeded)
    #expect(viewModel.monitoredSessionIds.isEmpty)
    #expect(await remover.relativeRemovals() == [
      WorktreeRelativeRemoval(path: worktreePath, parentRepoPath: repoPath, force: false)
    ])
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
  remover: RecordingWorktreeRemovalService = RecordingWorktreeRemovalService(),
  monitor: WorktreeDeletionMonitorService = WorktreeDeletionMonitorService()
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: monitor,
    fileWatcher: WorktreeDeletionFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService(),
    worktreeRemovalService: remover
  )
}

private final class WorktreeDeletionMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject: CurrentValueSubject<[SelectedRepository], Never>
  private var repositories: [SelectedRepository]

  init(repositories: [SelectedRepository] = []) {
    self.repositories = repositories
    self.subject = CurrentValueSubject(repositories)
  }

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { repositories }

  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    self.repositories = repositories
    subject.send(repositories)
  }

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
  private var relativeRemovalRecords: [WorktreeRelativeRemoval] = []

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
    relativeRemovalRecords.append(WorktreeRelativeRemoval(
      path: worktreePath,
      parentRepoPath: parentRepoPath,
      force: force
    ))
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

  func relativeRemovals() -> [WorktreeRelativeRemoval] {
    relativeRemovalRecords
  }
}

private struct WorktreeRelativeRemoval: Equatable, Sendable {
  let path: String
  let parentRepoPath: String
  let force: Bool
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

@MainActor
private func waitForDeletionViewModel(
  condition: @escaping @MainActor () -> Bool
) async {
  for _ in 0..<20 {
    if condition() { return }
    await Task.yield()
  }
}
