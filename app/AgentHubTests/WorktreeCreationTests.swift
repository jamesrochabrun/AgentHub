import Combine
import Foundation
import Testing
@testable import AgentHubCore

// MARK: - Minimal mocks for CLISessionsViewModel dependencies

private final class MockMonitorService: SessionMonitorServiceProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<[SelectedRepository], Never>()
  var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> { subject.eraseToAnyPublisher() }
  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

private final class MockFileWatcher: SessionFileWatcherProtocol, @unchecked Sendable {
  private let subject = PassthroughSubject<SessionFileWatcher.StateUpdate, Never>()
  var statePublisher: AnyPublisher<SessionFileWatcher.StateUpdate, Never> { subject.eraseToAnyPublisher() }
  func startMonitoring(sessionId: String, projectPath: String, sessionFilePath: String?) async {}
  func stopMonitoring(sessionId: String) async {}
  func getState(sessionId: String) async -> SessionMonitorState? { nil }
  func refreshState(sessionId: String) async {}
  func setApprovalTimeout(_ seconds: Int) async {}
}

@MainActor
private func makeViewModel() -> MultiSessionLaunchViewModel {
  makeViewModelFixture().viewModel
}

@MainActor
private func makeViewModelFixture(
  namingService: (any WorktreeBranchNamingServiceProtocol)? = nil,
  successSoundService: (any WorktreeSuccessSoundServiceProtocol)? = nil
) -> (viewModel: MultiSessionLaunchViewModel, claudeViewModel: CLISessionsViewModel, codexViewModel: CLISessionsViewModel) {
  let claudeVM = CLISessionsViewModel(
    monitorService: MockMonitorService(),
    fileWatcher: MockFileWatcher(),
    searchService: nil,
    cliConfiguration: .claudeDefault,
    providerKind: .claude,
    requestNotificationPermissionsOnInit: false
  )
  let codexVM = CLISessionsViewModel(
    monitorService: MockMonitorService(),
    fileWatcher: MockFileWatcher(),
    searchService: nil,
    cliConfiguration: .codexDefault,
    providerKind: .codex,
    requestNotificationPermissionsOnInit: false
  )
  let viewModel = MultiSessionLaunchViewModel(
    claudeViewModel: claudeVM,
    codexViewModel: codexVM,
    worktreeBranchNamingService: namingService,
    worktreeSuccessSoundService: successSoundService
  )
  return (viewModel, claudeVM, codexVM)
}

private actor MockWorktreeBranchNamingService: WorktreeBranchNamingServiceProtocol {
  private(set) var requests: [WorktreeBranchNamingRequest] = []
  private let result: WorktreeBranchNamingResult
  private let progressUpdates: [WorktreeBranchNamingProgress]
  private let delay: Duration?
  private(set) var cancelCallCount = 0

  init(
    result: WorktreeBranchNamingResult,
    progressUpdates: [WorktreeBranchNamingProgress] = [],
    delay: Duration? = nil
  ) {
    self.result = result
    self.progressUpdates = progressUpdates
    self.delay = delay
  }

  func resolveBranchNames(
    for request: WorktreeBranchNamingRequest,
    onProgress: (@MainActor @Sendable (WorktreeBranchNamingProgress) -> Void)?
  ) async throws -> WorktreeBranchNamingResult {
    requests.append(request)
    for update in progressUpdates {
      guard let onProgress else { continue }
      await onProgress(update)
    }
    if let delay {
      try await Task.sleep(for: delay)
      try Task.checkCancellation()
      if cancelCallCount > 0 {
        throw CancellationError()
      }
    }
    return result
  }

  func cancelActiveRequest() async {
    cancelCallCount += 1
  }

  func recordedRequests() -> [WorktreeBranchNamingRequest] {
    requests
  }

  func recordedCancelCallCount() -> Int {
    cancelCallCount
  }
}

private actor MockWorktreeSuccessSoundService: WorktreeSuccessSoundServiceProtocol {
  private(set) var playCallCount = 0

  func playWorktreeCreatedSound() async {
    playCallCount += 1
  }

  func recordedPlayCallCount() -> Int {
    playCallCount
  }
}

private struct LauncherGitRepoFixture {
  let repoPath: String
  let parentDir: String

  static func create() throws -> LauncherGitRepoFixture {
    let parentDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubLauncherTests-\(UUID().uuidString)", isDirectory: true)
    let repoURL = parentDir.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

    let fixture = LauncherGitRepoFixture(repoPath: repoURL.path, parentDir: parentDir.path)
    try fixture.runGit("init", "-b", "main")
    try fixture.runGit("config", "user.email", "test@test.com")
    try fixture.runGit("config", "user.name", "Test")
    try "initial".write(toFile: repoURL.appendingPathComponent("README.md").path, atomically: true, encoding: .utf8)
    try fixture.runGit("add", ".")
    try fixture.runGit("commit", "-m", "initial")
    return fixture
  }

  @discardableResult
  func runGit(_ args: String..., at path: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: path ?? repoPath)

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    if process.terminationStatus != 0 {
      throw NSError(domain: "LauncherGitRepoFixture", code: Int(process.terminationStatus), userInfo: [
        NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(error)"
      ])
    }

    return output
  }

  func cleanup() {
    try? FileManager.default.removeItem(atPath: parentDir)
  }
}

// MARK: - CLICommandConfiguration --worktree flag tests

@Suite("CLICommandConfiguration.argumentsForSession — worktree flag")
struct CLICommandConfigurationWorktreeTests {

  private let config = CLICommandConfiguration.claudeDefault

  @Test("No --worktree flag when worktreeName is nil")
  func noWorktreeFlagWhenNil() {
    let args = config.argumentsForSession(sessionId: nil, prompt: nil, worktreeName: nil)
    #expect(!args.contains("--worktree"))
  }

  @Test("Emits bare --worktree when name is empty")
  func bareWorktreeFlagForEmptyName() {
    let args = config.argumentsForSession(sessionId: nil, prompt: nil, worktreeName: "")
    #expect(args.contains("--worktree"))
    // No branch-name value should follow
    if let idx = args.firstIndex(of: "--worktree") {
      let next = args.index(after: idx)
      if next < args.endIndex {
        #expect(args[next].hasPrefix("-"), "Expected no branch-name argument after bare --worktree")
      }
    }
  }

  @Test("Bare --worktree appears before prompt")
  func bareWorktreeFlagBeforePrompt() {
    let args = config.argumentsForSession(sessionId: nil, prompt: "do something", worktreeName: "")
    #expect(args.contains("--worktree"))
    #expect(args.last == "do something")
  }

  @Test("Emits --worktree <name> for non-empty name")
  func namedWorktreeFlag() {
    let args = config.argumentsForSession(sessionId: nil, prompt: nil, worktreeName: "my-branch")
    guard let idx = args.firstIndex(of: "--worktree") else {
      Issue.record("Expected --worktree flag")
      return
    }
    let nameIdx = args.index(after: idx)
    #expect(nameIdx < args.endIndex)
    #expect(args[nameIdx] == "my-branch")
  }

  @Test("--worktree <name> appears before prompt")
  func namedWorktreeFlagBeforePrompt() {
    let args = config.argumentsForSession(sessionId: nil, prompt: "run tests", worktreeName: "feat-login")
    guard let idx = args.firstIndex(of: "--worktree") else {
      Issue.record("Expected --worktree flag")
      return
    }
    #expect(args[idx + 1] == "feat-login")
    #expect(args.last == "run tests")
  }

  @Test("--worktree not appended when resuming a real session")
  func noWorktreeFlagOnResume() {
    let args = config.argumentsForSession(
      sessionId: "abc-123",
      prompt: nil,
      worktreeName: "feat-login"
    )
    #expect(!args.contains("--worktree"))
    #expect(args.contains("-r"))
    #expect(args.contains("abc-123"))
  }

  @Test("--worktree not appended when resuming with prompt")
  func noWorktreeFlagOnResumeWithPrompt() {
    let args = config.argumentsForSession(
      sessionId: "real-session-id",
      prompt: "continue",
      worktreeName: "some-branch"
    )
    #expect(!args.contains("--worktree"))
  }

  @Test("--worktree appended for pending- session IDs (treated as new)")
  func worktreeFlagForPendingSession() {
    let args = config.argumentsForSession(
      sessionId: "pending-42",
      prompt: nil,
      worktreeName: "feat-x"
    )
    #expect(args.contains("--worktree"))
  }

  @Test("--worktree appended when sessionId is empty string")
  func worktreeFlagForEmptySessionId() {
    let args = config.argumentsForSession(
      sessionId: "",
      prompt: nil,
      worktreeName: "feat-x"
    )
    #expect(args.contains("--worktree"))
  }

  @Test("Both --dangerously-skip-permissions and --worktree emitted for new session")
  func dangerouslyAndWorktreeTogether() {
    let args = config.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      dangerouslySkipPermissions: true,
      worktreeName: "safe-branch"
    )
    #expect(args.contains("--dangerously-skip-permissions"))
    #expect(args.contains("--worktree"))
    if let idx = args.firstIndex(of: "--worktree") {
      #expect(args[idx + 1] == "safe-branch")
    }
  }

  @Test("Codex mode never emits --worktree")
  func codexIgnoresWorktreeName() {
    let codex = CLICommandConfiguration.codexDefault
    let args = codex.argumentsForSession(sessionId: nil, prompt: nil, worktreeName: "some-branch")
    #expect(!args.contains("--worktree"))
  }
}

// MARK: - MultiSessionLaunchViewModel claudeWorktreeOption tests

@Suite("MultiSessionLaunchViewModel — claudeWorktreeOption")
struct MultiSessionLaunchViewModelWorktreeOptionTests {

  @Test("Returns nil when Claude is disabled")
  @MainActor
  func nilWhenClaudeDisabled() {
    let vm = makeViewModel()
    vm.claudeMode = .disabled
    vm.claudeUseWorktree = true
    vm.claudeWorktreeName = "branch"
    #expect(vm.claudeWorktreeOption == nil)
  }

  @Test("Returns nil when claudeUseWorktree is false")
  @MainActor
  func nilWhenFlagOff() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.claudeUseWorktree = false
    vm.claudeWorktreeName = "branch"
    #expect(vm.claudeWorktreeOption == nil)
  }

  @Test("Returns empty string for auto-generated name")
  @MainActor
  func emptyStringForAutoName() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.claudeUseWorktree = true
    vm.claudeWorktreeName = ""
    #expect(vm.claudeWorktreeOption == "")
  }

  @Test("Returns branch name when set")
  @MainActor
  func returnsBranchName() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.claudeUseWorktree = true
    vm.claudeWorktreeName = "feat-new-ui"
    #expect(vm.claudeWorktreeOption == "feat-new-ui")
  }

  @Test("Returns non-nil for enabledDangerously mode")
  @MainActor
  func worksWithDangerousMode() {
    let vm = makeViewModel()
    vm.claudeMode = .enabledDangerously
    vm.claudeUseWorktree = true
    vm.claudeWorktreeName = "hotfix"
    #expect(vm.claudeWorktreeOption == "hotfix")
  }
}

// MARK: - MultiSessionLaunchViewModel reset() tests

@Suite("MultiSessionLaunchViewModel — reset clears worktree state")
struct MultiSessionLaunchViewModelResetTests {

  @Test("reset() sets claudeUseWorktree to false")
  @MainActor
  func resetClearsUseWorktree() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.claudeUseWorktree = true
    vm.reset()
    #expect(vm.claudeUseWorktree == false)
  }

  @Test("reset() clears claudeWorktreeName")
  @MainActor
  func resetClearsWorktreeName() {
    let vm = makeViewModel()
    vm.claudeUseWorktree = true
    vm.claudeWorktreeName = "some-branch"
    vm.reset()
    #expect(vm.claudeWorktreeName == "")
  }

  @Test("reset() leaves claudeWorktreeOption as nil")
  @MainActor
  func resetLeavesOptionNil() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.claudeUseWorktree = true
    vm.claudeWorktreeName = "branch"
    vm.reset()
    #expect(vm.claudeWorktreeOption == nil)
  }

  @Test("reset() clears branch naming progress state")
  @MainActor
  func resetClearsBranchNamingProgress() {
    let vm = makeViewModel()
    vm.branchNamingProgress = .queryingModel(model: "haiku", message: "Asking Claude Haiku")
    vm.branchNamingStartedAt = Date()
    vm.branchNamingCompletedAt = Date()

    vm.reset()

    #expect(vm.branchNamingProgress == .idle)
    #expect(vm.branchNamingStartedAt == nil)
    #expect(vm.branchNamingCompletedAt == nil)
  }
}

@Suite("MultiSessionLaunchViewModel — AI worktree naming")
struct MultiSessionLaunchViewModelAIWorktreeNamingTests {

  @Test("Manual worktree launch resolves names through the naming service")
  @MainActor
  func manualWorktreeLaunchUsesNamingService() async throws {
    let repo = try LauncherGitRepoFixture.create()
    defer { repo.cleanup() }

    let namingService = MockWorktreeBranchNamingService(
      result: WorktreeBranchNamingResult(
        single: "feature/ai-login-fix-abcdef",
        source: .ai
      )
    )
    let fixture = makeViewModelFixture(namingService: namingService)
    let viewModel = fixture.viewModel
    let claudeViewModel = fixture.claudeViewModel

    viewModel.selectedRepository = SelectedRepository(path: repo.repoPath, name: "repo")
    await viewModel.loadBranches()
    viewModel.workMode = .worktree
    viewModel.claudeMode = .enabled
    viewModel.sharedPrompt = "Fix the login flow"

    await viewModel.launchSessions()

    let requests = await namingService.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.launchContext == .manualWorktree)
    #expect(requests.first?.promptText == "Fix the login flow")

    #expect(claudeViewModel.pendingHubSessions.count == 1)
    let pending = try #require(claudeViewModel.pendingHubSessions.first)
    #expect(pending.worktree.name == "feature/ai-login-fix-abcdef")
    #expect(FileManager.default.fileExists(atPath: pending.worktree.path))

    claudeViewModel.pendingHubSessions.removeAll()
  }

  @Test("Smart fallback resolves names through the naming service")
  @MainActor
  func smartFallbackUsesNamingService() async throws {
    let namingService = MockWorktreeBranchNamingService(
      result: WorktreeBranchNamingResult(
        single: "feature/smart-rollout-abcdef",
        source: .ai
      )
    )
    let fixture = makeViewModelFixture(namingService: namingService)
    let viewModel = fixture.viewModel
    let repository = SelectedRepository(path: "/tmp/repo", name: "repo")

    let result = try await viewModel.resolveGeneratedBranchNames(
      for: repository,
      launchContext: .smartFallback,
      promptText: "Use the approved rollout plan",
      providerKinds: [.claude]
    )

    let requests = await namingService.recordedRequests()
    #expect(result.single == "feature/smart-rollout-abcdef")
    #expect(requests.count == 1)
    #expect(requests.first?.launchContext == .smartFallback)
    #expect(requests.first?.promptText == "Use the approved rollout plan")
  }

  @Test("Naming progress captures service updates and completion timing")
  @MainActor
  func namingProgressTracksServiceUpdates() async throws {
    let namingService = MockWorktreeBranchNamingService(
      result: WorktreeBranchNamingResult(
        single: "feature/live-progress-abcdef",
        source: .ai
      ),
      progressUpdates: [
        .preparingContext(message: "Preparing branch naming context"),
        .queryingModel(model: "haiku", message: "Generating branch name"),
        .sanitizing(message: "Finalizing branch name"),
      ]
    )
    let fixture = makeViewModelFixture(namingService: namingService)
    let viewModel = fixture.viewModel
    let repository = SelectedRepository(path: "/tmp/repo", name: "repo")

    let result = try await viewModel.resolveGeneratedBranchNames(
      for: repository,
      launchContext: .manualWorktree,
      promptText: "Live progress please",
      providerKinds: [.claude]
    )

    #expect(result.single == "feature/live-progress-abcdef")
    #expect(viewModel.branchNamingStartedAt != nil)
    #expect(viewModel.branchNamingCompletedAt != nil)
    #expect(viewModel.branchNamingProgress == .completed(
      message: "Branch name ready",
      source: .ai,
      branchNames: ["feature/live-progress-abcdef"]
    ))
  }

  @Test("Cancelling during naming preserves form state and stops before worktree creation")
  @MainActor
  func cancellingDuringNamingPreservesForm() async throws {
    let repo = try LauncherGitRepoFixture.create()
    defer { repo.cleanup() }

    let namingService = MockWorktreeBranchNamingService(
      result: WorktreeBranchNamingResult(
        single: "feature/late-result-abcdef",
        source: .ai
      ),
      progressUpdates: [
        .preparingContext(message: "Preparing repository context"),
        .queryingModel(model: "haiku", message: "Generating branch name"),
      ],
      delay: .seconds(2)
    )
    let fixture = makeViewModelFixture(namingService: namingService)
    let viewModel = fixture.viewModel
    let claudeViewModel = fixture.claudeViewModel

    viewModel.selectedRepository = SelectedRepository(path: repo.repoPath, name: "repo")
    await viewModel.loadBranches()
    viewModel.workMode = .worktree
    viewModel.claudeMode = .enabled
    viewModel.sharedPrompt = "Investigate the launcher cancellation path"

    viewModel.beginLaunch()
    try await Task.sleep(for: .milliseconds(100))
    viewModel.cancelLaunch()

    while viewModel.isLaunching {
      try await Task.sleep(for: .milliseconds(20))
    }

    #expect(await namingService.recordedCancelCallCount() == 1)
    #expect(viewModel.sharedPrompt == "Investigate the launcher cancellation path")
    #expect(viewModel.selectedRepository?.path == repo.repoPath)
    #expect(viewModel.singleBranchName.isEmpty)
    #expect(viewModel.branchNamingProgress == .cancelled(message: "Branch naming cancelled"))
    #expect(viewModel.lastLaunchEndedByCancellation)
    #expect(claudeViewModel.pendingHubSessions.isEmpty)
  }

  @Test("Successful single-provider worktree creation plays one success sound")
  @MainActor
  func singleProviderLaunchPlaysSuccessSound() async throws {
    let repo = try LauncherGitRepoFixture.create()
    defer { repo.cleanup() }

    let namingService = MockWorktreeBranchNamingService(
      result: WorktreeBranchNamingResult(
        single: "feature/sound-check-abcdef",
        source: .ai
      )
    )
    let successSoundService = MockWorktreeSuccessSoundService()
    let fixture = makeViewModelFixture(
      namingService: namingService,
      successSoundService: successSoundService
    )
    let viewModel = fixture.viewModel

    viewModel.selectedRepository = SelectedRepository(path: repo.repoPath, name: "repo")
    await viewModel.loadBranches()
    viewModel.workMode = .worktree
    viewModel.claudeMode = .enabled
    viewModel.sharedPrompt = "Verify the launcher status"

    await viewModel.launchSessions()

    #expect(await successSoundService.recordedPlayCallCount() == 1)
  }

  @Test("Successful dual-provider worktree creation plays one sound per worktree")
  @MainActor
  func dualProviderLaunchPlaysTwoSuccessSounds() async throws {
    let repo = try LauncherGitRepoFixture.create()
    defer { repo.cleanup() }

    let namingService = MockWorktreeBranchNamingService(
      result: WorktreeBranchNamingResult(
        claude: "feature/dual-sound-abcdef-claude",
        codex: "feature/dual-sound-abcdef-codex",
        source: .ai
      )
    )
    let successSoundService = MockWorktreeSuccessSoundService()
    let fixture = makeViewModelFixture(
      namingService: namingService,
      successSoundService: successSoundService
    )
    let viewModel = fixture.viewModel

    viewModel.selectedRepository = SelectedRepository(path: repo.repoPath, name: "repo")
    await viewModel.loadBranches()
    viewModel.workMode = .worktree
    viewModel.claudeMode = .enabled
    viewModel.isCodexSelected = true
    viewModel.sharedPrompt = "Split the validation and UI follow-up work"

    await viewModel.launchSessions()

    #expect(await successSoundService.recordedPlayCallCount() == 2)
  }
}

// MARK: - worktreeRow visibility condition (logic mirroring the View)

@Suite("worktreeRow visibility condition")
struct WorktreeRowVisibilityTests {

  /// Mirrors the condition in MultiSessionLaunchView:
  ///   selectedRepository != nil && isClaudeSelected && !isCodexSelected && workMode == .local
  @MainActor
  private func isWorktreeRowVisible(_ vm: MultiSessionLaunchViewModel) -> Bool {
    vm.selectedRepository != nil
      && vm.isClaudeSelected
      && !vm.isCodexSelected
      && vm.workMode == .local
  }

  @Test("Hidden when no repository selected")
  @MainActor
  func hiddenWithoutRepo() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.isCodexSelected = false
    vm.workMode = .local
    vm.selectedRepository = nil
    #expect(isWorktreeRowVisible(vm) == false)
  }

  @Test("Hidden when Claude is not selected")
  @MainActor
  func hiddenWhenClaudeDisabled() {
    let vm = makeViewModel()
    vm.claudeMode = .disabled
    vm.isCodexSelected = false
    vm.workMode = .local
    vm.selectedRepository = SelectedRepository(path: "/repo", name: "repo")
    #expect(isWorktreeRowVisible(vm) == false)
  }

  @Test("Hidden when Codex is also selected")
  @MainActor
  func hiddenWhenCodexAlsoSelected() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.isCodexSelected = true
    vm.workMode = .local
    vm.selectedRepository = SelectedRepository(path: "/repo", name: "repo")
    #expect(isWorktreeRowVisible(vm) == false)
  }

  @Test("Hidden when workMode is .worktree")
  @MainActor
  func hiddenInWorktreeMode() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.isCodexSelected = false
    vm.workMode = .worktree
    vm.selectedRepository = SelectedRepository(path: "/repo", name: "repo")
    #expect(isWorktreeRowVisible(vm) == false)
  }

  @Test("Visible when repo selected, Claude only, local mode")
  @MainActor
  func visibleForValidCondition() {
    let vm = makeViewModel()
    vm.claudeMode = .enabled
    vm.isCodexSelected = false
    vm.workMode = .local
    vm.selectedRepository = SelectedRepository(path: "/repo", name: "repo")
    #expect(isWorktreeRowVisible(vm) == true)
  }
}

// MARK: - CLICommandConfiguration plan mode tests

@Suite("CLICommandConfiguration.argumentsForSession — plan mode")
struct CLICommandConfigurationPlanModeTests {

  private let claude = CLICommandConfiguration.claudeDefault
  private let codex  = CLICommandConfiguration.codexDefault

  // MARK: Claude

  @Test("Claude emits --permission-mode plan when permissionModePlan is true")
  func claudePlanModeFlag() {
    let args = claude.argumentsForSession(sessionId: nil, prompt: nil, permissionModePlan: true)
    guard let idx = args.firstIndex(of: "--permission-mode") else {
      Issue.record("Expected --permission-mode flag")
      return
    }
    let valueIdx = args.index(after: idx)
    #expect(valueIdx < args.endIndex)
    #expect(args[valueIdx] == "plan")
  }

  @Test("Claude plan mode takes precedence over dangerouslySkipPermissions")
  func claudePlanModePrecedence() {
    let args = claude.argumentsForSession(
      sessionId: nil,
      prompt: nil,
      dangerouslySkipPermissions: true,
      permissionModePlan: true
    )
    #expect(args.contains("--permission-mode"))
    #expect(!args.contains("--dangerously-skip-permissions"))
  }

  @Test("Claude does not emit --permission-mode when plan mode is off")
  func claudeNoPlanModeByDefault() {
    let args = claude.argumentsForSession(sessionId: nil, prompt: nil, permissionModePlan: false)
    #expect(!args.contains("--permission-mode"))
  }

  @Test("Claude plan mode flag appears before prompt")
  func claudePlanModeFlagBeforePrompt() {
    let args = claude.argumentsForSession(sessionId: nil, prompt: "fix bug", permissionModePlan: true)
    #expect(args.last == "fix bug")
    #expect(args.contains("--permission-mode"))
  }

  // MARK: Codex

  @Test("Codex emits no --ask-for-approval flag when permissionModePlan is true")
  func codexNoApprovalFlagInPlanMode() {
    let args = codex.argumentsForSession(sessionId: nil, prompt: nil, permissionModePlan: true)
    #expect(!args.contains("--ask-for-approval"))
  }

  @Test("Codex with plan mode true and a prompt emits only the prompt")
  func codexPlanModeWithPrompt() {
    let args = codex.argumentsForSession(sessionId: nil, prompt: "do work", permissionModePlan: true)
    #expect(args == ["do work"])
  }

  @Test("Codex with plan mode true and no prompt emits empty args")
  func codexPlanModeNoPrompt() {
    let args = codex.argumentsForSession(sessionId: nil, prompt: nil, permissionModePlan: true)
    #expect(args.isEmpty)
  }

  @Test("Codex resume ignores permissionModePlan")
  func codexResumeIgnoresPlanMode() {
    let args = codex.argumentsForSession(
      sessionId: "abc-123",
      prompt: nil,
      permissionModePlan: true
    )
    #expect(args.contains("resume"))
    #expect(args.contains("abc-123"))
    #expect(!args.contains("--ask-for-approval"))
  }
}

// MARK: - MultiSessionLaunchViewModel plan mode tests

@Suite("MultiSessionLaunchViewModel — plan mode")
struct MultiSessionLaunchViewModelPlanModeTests {

  /// Mirrors the condition in MultiSessionLaunchView:
  ///   disabled: viewModel.isPlanModeEnabled
  @MainActor
  private func isCodexPillDisabled(_ vm: MultiSessionLaunchViewModel) -> Bool {
    vm.isPlanModeEnabled
  }

  @Test("isPlanModeEnabled defaults to false")
  @MainActor
  func defaultsToFalse() {
    let vm = makeViewModel()
    #expect(vm.isPlanModeEnabled == false)
  }

  @Test("reset() clears isPlanModeEnabled")
  @MainActor
  func resetClearsPlanMode() {
    let vm = makeViewModel()
    vm.isPlanModeEnabled = true
    vm.reset()
    #expect(vm.isPlanModeEnabled == false)
  }

  @Test("Codex pill is not disabled when plan mode is off")
  @MainActor
  func codexPillEnabledByDefault() {
    let vm = makeViewModel()
    #expect(isCodexPillDisabled(vm) == false)
  }

  @Test("Codex pill is disabled when plan mode is on")
  @MainActor
  func codexPillDisabledInPlanMode() {
    let vm = makeViewModel()
    vm.isPlanModeEnabled = true
    #expect(isCodexPillDisabled(vm) == true)
  }

  @Test("selectedProviders excludes Codex when Codex is deselected in plan mode")
  @MainActor
  func selectedProvidersExcludesCodexInPlanMode() {
    let vm = makeViewModel()
    vm.isPlanModeEnabled = true
    vm.isCodexSelected = false   // UI enforces this via .onChange
    vm.claudeMode = .enabled
    #expect(!vm.selectedProviders.contains(.codex))
    #expect(vm.selectedProviders.contains(.claude))
  }
}
