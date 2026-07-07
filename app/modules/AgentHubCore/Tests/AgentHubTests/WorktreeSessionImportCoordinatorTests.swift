import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("Worktree session import coordinator")
@MainActor
struct WorktreeSessionImportCoordinatorTests {
  @Test("Initial import brings only the newest session across providers")
  func initialImportBringsNewestSessionAcrossProviders() async throws {
    let worktree = settingsWorktree()
    let claudeMonitor = ImportMonitorService(sessions: [
      importSession("claude-1", path: worktree.path, timestamp: 100),
      importSession("claude-2", path: worktree.path, timestamp: 90),
      importSession("claude-3", path: worktree.path, timestamp: 50),
    ])
    let codexMonitor = ImportMonitorService(sessions: [
      importSession("codex-1", path: worktree.path, timestamp: 95),
      importSession("codex-2", path: worktree.path, timestamp: 80),
    ])
    let claudeViewModel = importViewModel(provider: .claude, monitor: claudeMonitor)
    let codexViewModel = importViewModel(provider: .codex, monitor: codexMonitor)
    let coordinator = WorktreeSessionImportCoordinator()

    await coordinator.importInitial(
      worktree,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel
    )

    #expect(claudeViewModel.monitoredSessionIds == Set(["claude-1"]))
    #expect(codexViewModel.monitoredSessionIds.isEmpty)
    #expect(coordinator.canShowMore(worktree))
  }

  @Test("Show more excludes already imported sessions")
  func showMoreExcludesAlreadyImportedSessions() async throws {
    let worktree = settingsWorktree()
    let claudeMonitor = ImportMonitorService(sessions: [
      importSession("claude-1", path: worktree.path, timestamp: 100),
      importSession("claude-2", path: worktree.path, timestamp: 90),
      importSession("claude-3", path: worktree.path, timestamp: 50),
    ])
    let codexMonitor = ImportMonitorService(sessions: [
      importSession("codex-1", path: worktree.path, timestamp: 95),
      importSession("codex-2", path: worktree.path, timestamp: 80),
    ])
    let claudeViewModel = importViewModel(provider: .claude, monitor: claudeMonitor)
    let codexViewModel = importViewModel(provider: .codex, monitor: codexMonitor)
    let coordinator = WorktreeSessionImportCoordinator()

    await coordinator.importInitial(
      worktree,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel
    )
    await coordinator.showMore(
      worktree,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel
    )
    await coordinator.showMore(
      worktree,
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel
    )

    #expect(await claudeMonitor.loadExclusionRequests() == [
      Set<String>(),
      Set(["claude-1"]),
      Set(["claude-1", "claude-2"]),
    ])
    #expect(await codexMonitor.loadExclusionRequests() == [
      Set<String>(),
      Set<String>(),
      Set(["codex-1", "codex-2"]),
    ])
    #expect(claudeViewModel.monitoredSessionIds == Set(["claude-1", "claude-2", "claude-3"]))
    #expect(codexViewModel.monitoredSessionIds == Set(["codex-1", "codex-2"]))
    #expect(!coordinator.canShowMore(worktree))
  }
}

private final class ImportMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = CurrentValueSubject<[SelectedRepository], Never>([])
  private let sessions: [CLISession]
  private var repositories: [SelectedRepository] = []
  private var loadRequests: [Set<String>] = []

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  init(sessions: [CLISession]) {
    self.sessions = sessions
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func addRepositories(_ paths: [String]) async {}
  func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository] { [] }
  func loadSessions(ids: Set<String>) async -> [CLISession] {
    sessions.filter { ids.contains($0.id) }
  }

  func loadLatestSessions(
    inWorktreePath worktreePath: String,
    excludingSessionIds: Set<String>,
    limit: Int
  ) async -> WorktreeSessionImportPage {
    loadRequests.append(excludingSessionIds)
    let normalizedWorktreePath = WorktreeModuleResolver.normalizedDirectoryPath(worktreePath)
    let filtered = sessions
      .filter { session in
        guard !excludingSessionIds.contains(session.id) else { return false }
        let projectPath = WorktreeModuleResolver.normalizedDirectoryPath(session.projectPath)
        return projectPath == normalizedWorktreePath || projectPath.hasPrefix(normalizedWorktreePath + "/")
      }
      .sorted { $0.lastActivityAt > $1.lastActivityAt }

    return WorktreeSessionImportPage(
      sessions: Array(filtered.prefix(limit)),
      hasMore: filtered.count > limit
    )
  }

  func removeRepository(_ path: String) async {}
  func setOwnedWorktreePaths(_ paths: Set<String>) async {}
  func setFocusedSessionIds(_ ids: Set<String>) async {}

  func registerWorktree(_ worktree: WorktreeBranch, parentRepositoryPath: String) async {
    let normalizedParentPath = WorktreeModuleResolver.normalizedDirectoryPath(parentRepositoryPath)
    let normalizedWorktree = WorktreeBranch(
      name: worktree.name,
      path: WorktreeModuleResolver.normalizedDirectoryPath(worktree.path),
      isWorktree: true,
      sessions: worktree.sessions,
      isExpanded: true
    )

    if let repositoryIndex = repositories.firstIndex(where: { $0.path == normalizedParentPath }) {
      if let worktreeIndex = repositories[repositoryIndex].worktrees.firstIndex(where: { $0.path == normalizedWorktree.path }) {
        repositories[repositoryIndex].worktrees[worktreeIndex] = normalizedWorktree
      } else {
        repositories[repositoryIndex].worktrees.append(normalizedWorktree)
      }
    } else {
      repositories.append(SelectedRepository(
        path: normalizedParentPath,
        worktrees: [
          WorktreeBranch(name: "main", path: normalizedParentPath, isWorktree: false),
          normalizedWorktree,
        ]
      ))
    }
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

  func loadExclusionRequests() async -> [Set<String>] {
    loadRequests
  }
}

private actor ImportFileWatcher: SessionFileWatcherProtocol {
  nonisolated(unsafe) private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()

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
private func importViewModel(
  provider: SessionProviderKind,
  monitor: ImportMonitorService
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: monitor,
    fileWatcher: ImportFileWatcher(),
    searchService: nil,
    cliConfiguration: CLICommandConfiguration(command: provider == .claude ? "claude" : "codex", mode: provider == .claude ? .claude : .codex),
    providerKind: provider,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
}

private func settingsWorktree() -> WorktreeSettingsWorktree {
  let path = "/tmp/AgentHub-feature"
  return WorktreeSettingsWorktree(
    branchName: "feature/import",
    path: path,
    worktree: WorktreeBranch(name: "feature/import", path: path, isWorktree: true),
    parentModulePath: "/tmp/AgentHub",
    providerKinds: [],
    isFocusedInAgentHub: false,
    monitoredSessionCount: 0,
    activeMonitoredSessionCount: 0,
    historicalSessionCount: 0,
    diskSizeBytes: nil
  )
}

private func importSession(_ id: String, path: String, timestamp: TimeInterval) -> CLISession {
  CLISession(
    id: id,
    projectPath: path,
    branchName: "feature/import",
    isWorktree: true,
    lastActivityAt: Date(timeIntervalSince1970: timestamp),
    firstMessage: id,
    sessionFilePath: "/tmp/\(id).jsonl"
  )
}
