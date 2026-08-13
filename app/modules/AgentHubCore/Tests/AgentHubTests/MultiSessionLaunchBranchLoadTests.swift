import Combine
import Foundation
import Testing

@testable import AgentHubCore

// Guards the non-blocking launch-sheet contract: repository selection and fork
// configuration are synchronous so the sheet can present immediately, while
// `loadBranches` runs behind the sheet's loading state — and a load finishing
// late must never stomp values the flow seeded (fork's `baseBranch = nil`).

@Suite("MultiSessionLaunchViewModel branch loading")
@MainActor
struct MultiSessionLaunchBranchLoadTests {

  @Test("Fork configures synchronously and the branch load preserves the seeded base")
  func forkConfiguresSynchronouslyAndLoadPreservesSeededBase() async throws {
    let repo = try BranchLoadGitRepoFixture.create()
    defer { repo.cleanup() }

    let viewModel = makeBranchLoadFixtureViewModel()
    let session = CLISession(
      id: "abcdef1234567890",
      projectPath: repo.repoPath,
      branchName: "main",
      sessionFilePath: repo.repoPath + "/session.jsonl"
    )

    let didConfigure = viewModel.configureForFork(from: session, targetProvider: .codex)

    // Everything the sheet needs is seeded before any git call completes.
    #expect(didConfigure)
    #expect(viewModel.selectedRepository?.path == repo.repoPath)
    #expect(viewModel.baseBranch == nil)
    #expect(viewModel.currentBranchName == "main")
    #expect(viewModel.isLoadingBranches)

    try await waitUntil { !viewModel.isLoadingBranches }

    // The load fills the picker but must not apply the remote/local default
    // over fork's deliberate "current HEAD" base.
    #expect(viewModel.baseBranch == nil)
    #expect(viewModel.currentBranchName == "main")
    #expect(viewModel.availableBranches.contains { $0.name == "main" })
  }

  @Test("Default branch load still applies a base branch when nothing was seeded")
  func defaultBranchLoadAppliesBase() async throws {
    let repo = try BranchLoadGitRepoFixture.create()
    defer { repo.cleanup() }

    let viewModel = makeBranchLoadFixtureViewModel()
    viewModel.selectedRepository = SelectedRepository(path: repo.repoPath)

    await viewModel.loadBranches()

    #expect(viewModel.currentBranchName == "main")
    #expect(viewModel.baseBranch != nil)
    #expect(viewModel.isLoadingBranches == false)
  }
}

// MARK: - Fixture

@MainActor
private func makeBranchLoadFixtureViewModel() -> MultiSessionLaunchViewModel {
  let claudeViewModel = CLISessionsViewModel(
    monitorService: BranchLoadMonitorService(),
    fileWatcher: BranchLoadFileWatcher(),
    searchService: nil,
    cliConfiguration: .claudeDefault,
    providerKind: .claude,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
  let codexViewModel = CLISessionsViewModel(
    monitorService: BranchLoadMonitorService(),
    fileWatcher: BranchLoadFileWatcher(),
    searchService: nil,
    cliConfiguration: .codexDefault,
    providerKind: .codex,
    approvalNotificationService: NoOpApprovalNotificationService()
  )
  return MultiSessionLaunchViewModel(
    claudeViewModel: claudeViewModel,
    codexViewModel: codexViewModel
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

private struct BranchLoadGitRepoFixture {
  let repoPath: String
  let parentDir: String

  static func create() throws -> BranchLoadGitRepoFixture {
    let parentDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubBranchLoadTests-\(UUID().uuidString)", isDirectory: true)
    let repoURL = parentDir.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

    let fixture = BranchLoadGitRepoFixture(repoPath: repoURL.path, parentDir: parentDir.path)
    try fixture.runGit("init", "-b", "main")
    try fixture.runGit("config", "user.email", "test@test.com")
    try fixture.runGit("config", "user.name", "Test")
    try "initial".write(toFile: repoURL.appendingPathComponent("README.md").path, atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "initial")
    return fixture
  }

  private func runGit(_ args: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "BranchLoadGitRepoFixture", code: Int(process.terminationStatus))
    }
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: parentDir)
  }
}

private final class BranchLoadMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = CurrentValueSubject<[SelectedRepository], Never>([])

  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    subject.eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class BranchLoadFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
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
