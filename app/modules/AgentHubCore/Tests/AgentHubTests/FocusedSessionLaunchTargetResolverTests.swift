import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("FocusedSessionLaunchTargetResolver")
struct FocusedSessionLaunchTargetResolverTests {
  @Test("No primary session returns no launch path")
  func noPrimarySessionReturnsNil() {
    let repository = repositoryWithWorktree()

    let path = FocusedSessionLaunchTargetResolver.launchPath(
      primarySessionId: nil,
      selectedModuleLandingPath: nil,
      items: [
        .init(id: "claude-session", projectPath: "/tmp/Repo")
      ],
      repositories: [repository]
    )

    #expect(path == nil)
  }

  @Test("Module landing selection returns no launch path")
  func moduleLandingSelectionReturnsNil() {
    let repository = repositoryWithWorktree()

    let path = FocusedSessionLaunchTargetResolver.launchPath(
      primarySessionId: "claude-session",
      selectedModuleLandingPath: "/tmp/Repo",
      items: [
        .init(id: "claude-session", projectPath: "/tmp/Repo")
      ],
      repositories: [repository]
    )

    #expect(path == nil)
  }

  @Test("Focused worktree session resolves to worktree root")
  func focusedWorktreeSessionResolvesToWorktreeRoot() {
    let repository = repositoryWithWorktree()

    let path = FocusedSessionLaunchTargetResolver.launchPath(
      primarySessionId: "codex-session",
      selectedModuleLandingPath: nil,
      items: [
        .init(id: "codex-session", projectPath: "/tmp/Repo-feature/app")
      ],
      repositories: [repository]
    )

    #expect(path == "/tmp/Repo-feature")
  }

  @Test("Focused main repo session resolves to repository root")
  func focusedMainRepoSessionResolvesToRepositoryRoot() {
    let repository = repositoryWithWorktree()

    let path = FocusedSessionLaunchTargetResolver.launchPath(
      primarySessionId: "claude-session",
      selectedModuleLandingPath: nil,
      items: [
        .init(id: "claude-session", projectPath: "/tmp/Repo/Sources")
      ],
      repositories: [repository]
    )

    #expect(path == "/tmp/Repo")
  }

  @Test("Unmatched focused session returns no launch path")
  func unmatchedFocusedSessionReturnsNil() {
    let repository = repositoryWithWorktree()

    let path = FocusedSessionLaunchTargetResolver.launchPath(
      primarySessionId: "claude-session",
      selectedModuleLandingPath: nil,
      items: [
        .init(id: "claude-session", projectPath: "/tmp/Other")
      ],
      repositories: [repository]
    )

    #expect(path == nil)
  }
}

@Suite("GitHubReviewSessionLaunchTargetResolver")
struct GitHubReviewSessionLaunchTargetResolverTests {
  @Test("Tracked repository resolves to local main repository target")
  func trackedRepositoryResolvesToMainRepositoryTarget() {
    let target = GitHubReviewSessionLaunchTargetResolver.launchTarget(
      for: "/tmp/Repo/",
      repositories: [repositoryWithWorktree()]
    )

    #expect(target.worktree.name == "main")
    #expect(target.worktree.path == "/tmp/Repo")
    #expect(target.worktree.isWorktree == false)
    #expect(target.parentRepositoryPath == nil)
  }

  @Test("Tracked worktree module resolves to worktree target with parent repository")
  func trackedWorktreeModuleResolvesToWorktreeTarget() {
    let target = GitHubReviewSessionLaunchTargetResolver.launchTarget(
      for: "/tmp/Repo-feature",
      repositories: [repositoryWithWorktree()]
    )

    #expect(target.worktree.name == "feature")
    #expect(target.worktree.path == "/tmp/Repo-feature")
    #expect(target.worktree.isWorktree)
    #expect(target.parentRepositoryPath == "/tmp/Repo")
  }

  @Test("Nested worktree path resolves to worktree root")
  func nestedWorktreePathResolvesToWorktreeRoot() {
    let target = GitHubReviewSessionLaunchTargetResolver.launchTarget(
      for: "/tmp/Repo-feature/App",
      repositories: [repositoryWithWorktree()]
    )

    #expect(target.worktree.path == "/tmp/Repo-feature")
    #expect(target.worktree.isWorktree)
    #expect(target.parentRepositoryPath == "/tmp/Repo")
  }

  @Test("Untracked project resolves to local directory target")
  func untrackedProjectResolvesToLocalDirectoryTarget() {
    let target = GitHubReviewSessionLaunchTargetResolver.launchTarget(
      for: "/tmp/Other",
      repositories: [repositoryWithWorktree()]
    )

    #expect(target.worktree.name == "Other")
    #expect(target.worktree.path == "/tmp/Other")
    #expect(target.worktree.isWorktree == false)
    #expect(target.parentRepositoryPath == nil)
  }
}

@Suite("MultiSessionLaunchViewModel preselection")
@MainActor
struct MultiSessionLaunchViewModelPreselectionTests {
  @Test("Preselect accepts a path inside a tracked main repository")
  func preselectAcceptsNestedMainRepositoryPath() async throws {
    let repository = repositoryWithWorktree()
    let fixture = makePreselectionFixture()

    await fixture.claudeMonitor.setRepositories([repository])
    try await waitUntil { fixture.claudeViewModel.selectedRepositories == [repository] }

    let didPreselect = await fixture.launchViewModel.preselectRepository(path: "/tmp/Repo/app")

    #expect(didPreselect)
    #expect(fixture.launchViewModel.selectedRepository?.path == "/tmp/Repo")
  }

  @Test("Preselect accepts a path inside a tracked worktree")
  func preselectAcceptsNestedWorktreePath() async throws {
    let repository = repositoryWithWorktree()
    let fixture = makePreselectionFixture()

    await fixture.claudeMonitor.setRepositories([repository])
    try await waitUntil { fixture.claudeViewModel.selectedRepositories == [repository] }

    let didPreselect = await fixture.launchViewModel.preselectRepository(path: "/tmp/Repo-feature/app")

    #expect(didPreselect)
    #expect(fixture.launchViewModel.selectedRepository?.path == "/tmp/Repo-feature")
  }
}

private func repositoryWithWorktree() -> SelectedRepository {
  SelectedRepository(
    path: "/tmp/Repo",
    worktrees: [
      WorktreeBranch(name: "main", path: "/tmp/Repo", isWorktree: false),
      WorktreeBranch(name: "feature", path: "/tmp/Repo-feature", isWorktree: true)
    ]
  )
}

@MainActor
private func makePreselectionFixture() -> (
  launchViewModel: MultiSessionLaunchViewModel,
  claudeViewModel: CLISessionsViewModel,
  claudeMonitor: PreselectionMonitorService
) {
  let claudeMonitor = PreselectionMonitorService()
  let codexMonitor = PreselectionMonitorService()
  let claudeViewModel = CLISessionsViewModel(
    monitorService: claudeMonitor,
    fileWatcher: PreselectionFileWatcher(),
    searchService: nil,
    cliConfiguration: .claudeDefault,
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
  let codexViewModel = CLISessionsViewModel(
    monitorService: codexMonitor,
    fileWatcher: PreselectionFileWatcher(),
    searchService: nil,
    cliConfiguration: .codexDefault,
    providerKind: .codex,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
  let launchViewModel = MultiSessionLaunchViewModel(
    claudeViewModel: claudeViewModel,
    codexViewModel: codexViewModel
  )
  return (launchViewModel, claudeViewModel, claudeMonitor)
}

@MainActor
private func waitUntil(
  _ condition: @escaping () -> Bool,
  timeoutAttempts: Int = 50
) async throws {
  for _ in 0..<timeoutAttempts {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition())
}

private final class PreselectionMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = CurrentValueSubject<[SelectedRepository], Never>([])
  private var repositories: [SelectedRepository] = []

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func setRepositories(_ repositories: [SelectedRepository]) async {
    self.repositories = repositories
    subject.send(repositories)
  }

  func addRepository(_ path: String) async -> SelectedRepository? {
    guard !repositories.contains(where: { $0.path == path }) else {
      return nil
    }

    let repository = SelectedRepository(path: path)
    repositories.append(repository)
    subject.send(repositories)
    return repository
  }

  func removeRepository(_ path: String) async {}

  func getSelectedRepositories() async -> [SelectedRepository] {
    repositories
  }

  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    await setRepositories(repositories)
  }

  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class PreselectionFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
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
