import AgentHubCLIKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("WorktreeLaunchRequestHandler")
@MainActor
struct WorktreeLaunchRequestHandlerTests {
  @Test("Handler registers worktree and launches pending session for requested provider")
  func handlerRegistersWorktreeAndLaunchesPendingSession() async throws {
    let claudeMonitor = TestLaunchMonitorService()
    let codexMonitor = TestLaunchMonitorService()
    let claudeViewModel = makeLaunchRequestViewModel(
      providerKind: .claude,
      monitorService: claudeMonitor
    )
    let codexViewModel = makeLaunchRequestViewModel(
      providerKind: .codex,
      monitorService: codexMonitor
    )
    let handler = WorktreeLaunchRequestHandler(
      claudeViewModel: claudeViewModel,
      codexViewModel: codexViewModel
    )
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-launch-handler-\(UUID().uuidString)", isDirectory: true)
    let repoPath = root.appendingPathComponent("repo", isDirectory: true).path
    let worktreePath = root.appendingPathComponent("repo/.worktrees/feature", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await handler.handle(WorktreeLaunchRequest(
      id: "request-1",
      provider: .codex,
      repositoryPath: repoPath,
      worktreePath: worktreePath,
      branchName: "feature",
      prompt: "Implement the feature"
    ))

    #expect(claudeViewModel.pendingHubSessions.isEmpty)
    let pending = try #require(codexViewModel.pendingHubSessions.first)
    #expect(pending.worktree.path == worktreePath)
    #expect(pending.worktree.name == "feature")
    #expect(pending.initialPrompt == "Implement the feature")
    #expect(
      codexViewModel.selectedRepositories.first?.worktrees.contains {
        $0.path == worktreePath && $0.isWorktree
      } == true
    )

    codexViewModel.cancelPendingSession(pending)
  }

  @Test("Handler strips worktree creation wording before launching child session")
  func handlerStripsWorktreeCreationWordingBeforeLaunchingChildSession() async throws {
    let codexViewModel = makeLaunchRequestViewModel(providerKind: .codex)
    let handler = WorktreeLaunchRequestHandler(
      claudeViewModel: makeLaunchRequestViewModel(providerKind: .claude),
      codexViewModel: codexViewModel
    )
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-launch-handler-\(UUID().uuidString)", isDirectory: true)
    let repoPath = root.appendingPathComponent("repo", isDirectory: true).path
    let worktreePath = root.appendingPathComponent("repo/.worktrees/logging", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await handler.handle(WorktreeLaunchRequest(
      provider: .codex,
      repositoryPath: repoPath,
      worktreePath: worktreePath,
      branchName: "logging",
      prompt: "create onw worktree I have to add logging"
    ))

    let pending = try #require(codexViewModel.pendingHubSessions.first)
    #expect(pending.initialPrompt == "add logging")

    codexViewModel.cancelPendingSession(pending)
  }

  @Test("Claude launches queue initial prompt for terminal submission")
  func claudeLaunchesQueueInitialPromptForTerminalSubmission() async throws {
    let claudeViewModel = makeLaunchRequestViewModel(providerKind: .claude)
    let handler = WorktreeLaunchRequestHandler(
      claudeViewModel: claudeViewModel,
      codexViewModel: makeLaunchRequestViewModel(providerKind: .codex)
    )
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-launch-handler-\(UUID().uuidString)", isDirectory: true)
    let repoPath = root.appendingPathComponent("repo", isDirectory: true).path
    let worktreePath = root.appendingPathComponent("repo/.worktrees/logging", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await handler.handle(WorktreeLaunchRequest(
      provider: .claude,
      repositoryPath: repoPath,
      worktreePath: worktreePath,
      branchName: "logging",
      prompt: "add logging"
    ))

    let pending = try #require(claudeViewModel.pendingHubSessions.first)
    #expect(pending.initialPrompt == nil)
    #expect(claudeViewModel.pendingPrompt(for: "pending-\(pending.id.uuidString)") == "add logging")

    claudeViewModel.cancelPendingSession(pending)
  }

  @Test("Handler falls back to branch name for worktree-only orchestration prompts")
  func handlerFallsBackToBranchNameForWorktreeOnlyOrchestrationPrompts() async throws {
    let codexViewModel = makeLaunchRequestViewModel(providerKind: .codex)
    let handler = WorktreeLaunchRequestHandler(
      claudeViewModel: makeLaunchRequestViewModel(providerKind: .claude),
      codexViewModel: codexViewModel
    )
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-launch-handler-\(UUID().uuidString)", isDirectory: true)
    let repoPath = root.appendingPathComponent("repo", isDirectory: true).path
    let worktreePath = root.appendingPathComponent("repo/.worktrees/review-tests", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await handler.handle(WorktreeLaunchRequest(
      provider: .codex,
      repositoryPath: repoPath,
      worktreePath: worktreePath,
      branchName: "review-tests",
      prompt: "create a worktree"
    ))

    let pending = try #require(codexViewModel.pendingHubSessions.first)
    #expect(pending.initialPrompt == "Work on review tests.")

    codexViewModel.cancelPendingSession(pending)
  }

  @Test("Handler rejects empty prompt")
  func handlerRejectsEmptyPrompt() async throws {
    let handler = WorktreeLaunchRequestHandler(
      claudeViewModel: makeLaunchRequestViewModel(providerKind: .claude),
      codexViewModel: makeLaunchRequestViewModel(providerKind: .codex)
    )

    await #expect(throws: WorktreeLaunchRequestHandlingError.self) {
      try await handler.handle(WorktreeLaunchRequest(
        provider: .claude,
        repositoryPath: "/tmp/repo",
        worktreePath: "/tmp/repo/.worktrees/feature",
        branchName: "feature",
        prompt: "   "
      ))
    }
  }
}

@MainActor
private func makeLaunchRequestViewModel(
  providerKind: SessionProviderKind,
  monitorService: TestLaunchMonitorService = TestLaunchMonitorService()
) -> CLISessionsViewModel {
  CLISessionsViewModel(
    monitorService: monitorService,
    fileWatcher: TestLaunchFileWatcher(),
    searchService: nil,
    cliConfiguration: providerKind == .claude ? .claudeDefault : .codexDefault,
    providerKind: providerKind,
    approvalNotificationService: TestLaunchApprovalNotificationService(),
    codexDataPath: FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-launch-codex-\(UUID().uuidString)", isDirectory: true)
      .path
  )
}

private final class TestLaunchApprovalNotificationService: ApprovalNotificationServiceProtocol, @unchecked Sendable {
  func requestPermission() async -> Bool { false }
  func sendApprovalNotification(sessionId: String, toolName: String, projectPath: String?, model: String?, lastMessage: String?) {}
}

private final class TestLaunchFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> { subject.eraseToAnyPublisher() }

  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

private actor TestLaunchMonitorService: SessionMonitorServiceProtocol {
  private nonisolated(unsafe) let subject = CurrentValueSubject<[SelectedRepository], Never>([])
  private var repositories: [SelectedRepository] = []
  private var ownedWorktreePaths: Set<String> = []

  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? {
    guard !repositories.contains(where: { $0.path == path }) else { return nil }
    let repository = SelectedRepository(path: path, worktrees: [
      WorktreeBranch(name: "main", path: path)
    ])
    repositories.append(repository)
    subject.send(repositories)
    return repository
  }

  func removeRepository(_ path: String) async {
    repositories.removeAll { $0.path == path }
    subject.send(repositories)
  }

  func setOwnedWorktreePaths(_ paths: Set<String>) async {
    ownedWorktreePaths = paths
  }

  func registerWorktree(_ worktree: WorktreeBranch, parentRepositoryPath: String) async {
    if let index = repositories.firstIndex(where: { $0.path == parentRepositoryPath }) {
      if let worktreeIndex = repositories[index].worktrees.firstIndex(where: { $0.path == worktree.path }) {
        repositories[index].worktrees[worktreeIndex] = worktree
      } else {
        repositories[index].worktrees.append(worktree)
      }
    } else {
      repositories.append(SelectedRepository(path: parentRepositoryPath, worktrees: [
        WorktreeBranch(name: "main", path: parentRepositoryPath),
        worktree
      ]))
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
}
