import Combine
import Foundation
import Testing

@testable import AgentHubCore
@testable import AgentHubGitDiff

private actor DiffAvailabilityEvaluatorSpy {
  private var queuedStatuses: [DiffAvailabilityStatus]
  private(set) var evaluationCount = 0
  private let delay: Duration?

  init(
    queuedStatuses: [DiffAvailabilityStatus],
    delay: Duration? = nil
  ) {
    self.queuedStatuses = queuedStatuses
    self.delay = delay
  }

  func evaluate(projectPath _: String) async -> DiffAvailabilityStatus {
    evaluationCount += 1
    if let delay {
      try? await Task.sleep(for: delay)
    }

    guard !queuedStatuses.isEmpty else {
      return .unavailable
    }

    return queuedStatuses.removeFirst()
  }
}

private actor MockDiffAvailabilityService: DiffAvailabilityServiceProtocol {
  private let status: DiffAvailabilityStatus
  private let cachedStatus: DiffAvailabilityStatus?
  private(set) var invalidatedProjectPaths: [String] = []

  init(
    status: DiffAvailabilityStatus = .unavailable,
    cachedStatus: DiffAvailabilityStatus? = nil
  ) {
    self.status = status
    self.cachedStatus = cachedStatus
  }

  func cachedAvailability(for projectPath: String) async -> DiffAvailabilityStatus? {
    cachedStatus
  }

  func availability(for projectPath: String) async -> DiffAvailabilityStatus {
    status
  }

  func invalidate(projectPath: String) async {
    invalidatedProjectPaths.append(projectPath)
  }

  func recordedInvalidations() -> [String] {
    invalidatedProjectPaths
  }
}

private actor MockLocalDiffSummaryService: LocalDiffSummaryServiceProtocol {
  private let summaryResult: LocalDiffSummary
  private let cachedSummaryResult: LocalDiffSummary?
  private(set) var invalidatedProjectPaths: [String] = []
  private(set) var summaryCallCount = 0

  init(
    summaryResult: LocalDiffSummary = .empty,
    cachedSummaryResult: LocalDiffSummary? = nil
  ) {
    self.summaryResult = summaryResult
    self.cachedSummaryResult = cachedSummaryResult
  }

  func cachedSummary(for projectPath: String) async -> LocalDiffSummary? {
    cachedSummaryResult
  }

  func summary(for projectPath: String) async -> LocalDiffSummary {
    summaryCallCount += 1
    return summaryResult
  }

  func invalidate(projectPath: String) async {
    invalidatedProjectPaths.append(projectPath)
  }

  func recordedInvalidations() -> [String] {
    invalidatedProjectPaths
  }
}

private actor DiffStubMonitorService: SessionMonitorServiceProtocol {
  nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    Empty<[SelectedRepository], Never>().eraseToAnyPublisher()
  }

  func addRepository(_ path: String) async -> SelectedRepository? { nil }
  func removeRepository(_ path: String) async {}
  func getSelectedRepositories() async -> [SelectedRepository] { [] }
  func setSelectedRepositories(_ repositories: [SelectedRepository]) async {}
  func refreshSessions(skipWorktreeRedetection: Bool) async {}
}

@Suite("CLISessionsViewModel Local Diff Summary")
struct CLISessionsViewModelLocalDiffSummaryTests {
  @Test("ensureLocalDiffSummary stores resolved summary")
  @MainActor
  func ensureLocalDiffSummaryStoresResolvedSummary() async {
    let summaryService = MockLocalDiffSummaryService(
      summaryResult: LocalDiffSummary(fileCount: 5, additions: 10, deletions: 2)
    )
    let viewModel = CLISessionsViewModel(
      monitorService: DiffStubMonitorService(),
      fileWatcher: DiffStubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      localDiffSummaryService: summaryService,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await viewModel.ensureLocalDiffSummary(for: "/tmp/project")

    #expect(viewModel.localDiffSummary(for: "/tmp/project")?.fileCount == 5)
    #expect(await summaryService.summaryCallCount == 1)
  }

  @Test("ensureLocalDiffSummary uses cached summary")
  @MainActor
  func ensureLocalDiffSummaryUsesCachedSummary() async {
    let summaryService = MockLocalDiffSummaryService(
      summaryResult: LocalDiffSummary(fileCount: 5, additions: 10, deletions: 2),
      cachedSummaryResult: LocalDiffSummary(fileCount: 2, additions: 3, deletions: 1)
    )
    let viewModel = CLISessionsViewModel(
      monitorService: DiffStubMonitorService(),
      fileWatcher: DiffStubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      localDiffSummaryService: summaryService,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await viewModel.ensureLocalDiffSummary(for: "/tmp/project")

    #expect(viewModel.localDiffSummary(for: "/tmp/project")?.fileCount == 2)
    #expect(await summaryService.summaryCallCount == 0)
  }

  @Test("force refresh invalidates local diff summary")
  @MainActor
  func forceRefreshInvalidatesLocalDiffSummary() async {
    let summaryService = MockLocalDiffSummaryService(
      summaryResult: LocalDiffSummary(fileCount: 5, additions: 10, deletions: 2),
      cachedSummaryResult: LocalDiffSummary(fileCount: 2, additions: 3, deletions: 1)
    )
    let viewModel = CLISessionsViewModel(
      monitorService: DiffStubMonitorService(),
      fileWatcher: DiffStubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      localDiffSummaryService: summaryService,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await viewModel.ensureLocalDiffSummary(for: "/tmp/project")
    await viewModel.ensureLocalDiffSummary(for: "/tmp/project", forceRefresh: true)

    #expect(viewModel.localDiffSummary(for: "/tmp/project")?.fileCount == 5)
    #expect(await summaryService.recordedInvalidations().count == 1)
  }
}

private actor DiffStubFileWatcher: SessionFileWatcherProtocol {
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

@Suite("DiffAvailabilityService")
struct DiffAvailabilityServiceTests {
  @Test("Clean repository is available")
  func cleanRepositoryIsAvailable() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }

    let status = await DiffAvailabilityService().availability(for: fixture.repoPath)

    #expect(status == .available)
  }

  @Test("Unstaged changes are available")
  func unstagedChangesAreAvailable() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)

    let status = await DiffAvailabilityService().availability(for: fixture.repoPath)

    #expect(status == .available)
  }

  @Test("Staged changes are available")
  func stagedChangesAreAvailable() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try "changed".write(toFile: fixture.repoPath + "/README.md", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "README.md")

    let status = await DiffAvailabilityService().availability(for: fixture.repoPath)

    #expect(status == .available)
  }

  @Test("Untracked changes are available")
  func untrackedChangesAreAvailable() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try "new".write(toFile: fixture.repoPath + "/NewFile.swift", atomically: true, encoding: .utf8)

    let status = await DiffAvailabilityService().availability(for: fixture.repoPath)

    #expect(status == .available)
  }

  @Test("Branch-only changes are available")
  func branchOnlyChangesAreAvailable() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    try fixture.runGit("switch", "-c", "feature/diff-availability")
    try "branch".write(toFile: fixture.repoPath + "/BranchFile.swift", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "BranchFile.swift")
    try fixture.runGit("commit", "-m", "branch change")

    let status = await DiffAvailabilityService().availability(for: fixture.repoPath)

    #expect(status == .available)
  }

  @Test("Clean git worktree is available")
  func cleanGitWorktreeIsAvailable() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-clean-worktree")
    try "parent only".write(toFile: fixture.repoPath + "/ParentOnly.swift", atomically: true, encoding: .utf8)

    let status = await DiffAvailabilityService().availability(for: worktreePath)

    #expect(status == .available)
  }

  @Test("Worktree branch changes are available from that worktree")
  func worktreeBranchChangesAreAvailableFromThatWorktree() async throws {
    let fixture = try GitRepoFixture.create()
    defer { fixture.cleanup() }
    let worktreePath = try fixture.addWorktree(branch: "feature-worktree-diff")
    try "worktree branch".write(toFile: worktreePath + "/WorktreeOnly.swift", atomically: true, encoding: .utf8)
    try fixture.runGit("add", "WorktreeOnly.swift", at: worktreePath)
    try fixture.runGit("commit", "-m", "worktree branch change", at: worktreePath)

    let status = await DiffAvailabilityService().availability(for: worktreePath)

    #expect(status == .available)
  }

  @Test("Non-git path is unavailable")
  func nonGitPathIsUnavailable() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("DiffAvailabilityNonGit-\(UUID().uuidString)", isDirectory: true)
      .path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let status = await DiffAvailabilityService().availability(for: path)

    #expect(status == .unavailable)
  }

  @Test("In-flight and cached calls reuse one evaluation")
  func inFlightAndCachedCallsReuseOneEvaluation() async {
    let evaluator = DiffAvailabilityEvaluatorSpy(
      queuedStatuses: [.available],
      delay: .milliseconds(100)
    )
    let service = DiffAvailabilityService(evaluator: { projectPath in
      await evaluator.evaluate(projectPath: projectPath)
    })

    async let first = service.availability(for: "/tmp/project")
    async let second = service.availability(for: "/tmp/project")

    let statuses = await [first, second]
    let cached = await service.availability(for: "/tmp/project")
    let evaluationCount = await evaluator.evaluationCount

    #expect(statuses == [.available, .available])
    #expect(cached == .available)
    #expect(evaluationCount == 1)
  }

  @Test("Invalidating an in-flight check reuses the active evaluation")
  func invalidatingInFlightCheckReusesActiveEvaluation() async {
    let evaluator = DiffAvailabilityEvaluatorSpy(
      queuedStatuses: [.available],
      delay: .milliseconds(100)
    )
    let service = DiffAvailabilityService(evaluator: { projectPath in
      await evaluator.evaluate(projectPath: projectPath)
    })

    async let first = service.availability(for: "/tmp/project")
    try? await Task.sleep(for: .milliseconds(10))
    await service.invalidate(projectPath: "/tmp/project")
    async let second = service.availability(for: "/tmp/project")

    let statuses = await [first, second]
    let evaluationCount = await evaluator.evaluationCount

    #expect(statuses == [.available, .available])
    #expect(evaluationCount == 1)
  }

  @Test("Adaptive throttle blocks invalidate inside the multiplied-duration window")
  func adaptiveThrottleBlocksInvalidateWithinWindow() async {
    let evaluator = DiffAvailabilityEvaluatorSpy(
      queuedStatuses: [.available, .unavailable],
      delay: .milliseconds(200)
    )
    let service = DiffAvailabilityService(
      evaluator: { projectPath in
        await evaluator.evaluate(projectPath: projectPath)
      },
      minimumRefreshInterval: 0,
      adaptiveThrottleMultiplier: 3
    )

    let first = await service.availability(for: "/tmp/project")
    await service.invalidate(projectPath: "/tmp/project")
    let second = await service.availability(for: "/tmp/project")
    let evaluationCount = await evaluator.evaluationCount

    #expect(first == .available)
    #expect(second == .available)
    #expect(evaluationCount == 1)
  }

  @Test("Invalidate succeeds after the adaptive window elapses")
  func invalidateSucceedsAfterAdaptiveWindow() async {
    let evaluator = DiffAvailabilityEvaluatorSpy(
      queuedStatuses: [.available, .unavailable],
      delay: .milliseconds(100)
    )
    let service = DiffAvailabilityService(
      evaluator: { projectPath in
        await evaluator.evaluate(projectPath: projectPath)
      },
      minimumRefreshInterval: 0,
      adaptiveThrottleMultiplier: 3
    )

    let first = await service.availability(for: "/tmp/project")
    try? await Task.sleep(for: .milliseconds(700))
    await service.invalidate(projectPath: "/tmp/project")
    let second = await service.availability(for: "/tmp/project")
    let evaluationCount = await evaluator.evaluationCount

    #expect(first == .available)
    #expect(second == .unavailable)
    #expect(evaluationCount == 2)
  }

  @Test("Fast evaluator keeps the minimum floor")
  func fastEvaluatorKeepsMinimumFloor() async {
    let evaluator = DiffAvailabilityEvaluatorSpy(
      queuedStatuses: [.available, .unavailable]
    )
    let service = DiffAvailabilityService(
      evaluator: { projectPath in
        await evaluator.evaluate(projectPath: projectPath)
      },
      minimumRefreshInterval: 0.1,
      adaptiveThrottleMultiplier: 3
    )

    let first = await service.availability(for: "/tmp/project")
    await service.invalidate(projectPath: "/tmp/project")
    let blocked = await service.availability(for: "/tmp/project")

    try? await Task.sleep(for: .milliseconds(300))
    await service.invalidate(projectPath: "/tmp/project")
    let second = await service.availability(for: "/tmp/project")
    let evaluationCount = await evaluator.evaluationCount

    #expect(first == .available)
    #expect(blocked == .available)
    #expect(second == .unavailable)
    #expect(evaluationCount == 2)
  }

  @Test("First invalidate before any evaluation is not blocked")
  func firstInvalidateBeforeAnyEvaluationIsNotBlocked() async {
    let evaluator = DiffAvailabilityEvaluatorSpy(
      queuedStatuses: [.available]
    )
    let service = DiffAvailabilityService(evaluator: { projectPath in
      await evaluator.evaluate(projectPath: projectPath)
    })

    await service.invalidate(projectPath: "/tmp/project")
    let status = await service.availability(for: "/tmp/project")
    let evaluationCount = await evaluator.evaluationCount

    #expect(status == .available)
    #expect(evaluationCount == 1)
  }
}

@Suite("CLISessionsViewModel Diff Availability")
struct CLISessionsViewModelDiffAvailabilityTests {
  @Test("ensureDiffAvailability stores the resolved status")
  @MainActor
  func ensureDiffAvailabilityStoresResolvedStatus() async {
    let diffService = MockDiffAvailabilityService(status: .available)
    let viewModel = CLISessionsViewModel(
      monitorService: DiffStubMonitorService(),
      fileWatcher: DiffStubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      diffAvailabilityService: diffService,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await viewModel.ensureDiffAvailability(for: "/tmp/project")

    #expect(viewModel.diffAvailabilityStatus(for: "/tmp/project") == .available)
  }

  @Test("ensureDiffAvailability uses the fresh cached status without rechecking")
  @MainActor
  func ensureDiffAvailabilityUsesFreshCachedStatus() async {
    let diffService = MockDiffAvailabilityService(
      status: .available,
      cachedStatus: .unavailable
    )
    let viewModel = CLISessionsViewModel(
      monitorService: DiffStubMonitorService(),
      fileWatcher: DiffStubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      diffAvailabilityService: diffService,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await viewModel.ensureDiffAvailability(for: "/tmp/project")

    #expect(viewModel.diffAvailabilityStatus(for: "/tmp/project") == .unavailable)
  }

  @Test("force refresh invalidates stale availability")
  @MainActor
  func forceRefreshInvalidatesStaleAvailability() async {
    let diffService = MockDiffAvailabilityService(
      status: .available,
      cachedStatus: .unavailable
    )
    let viewModel = CLISessionsViewModel(
      monitorService: DiffStubMonitorService(),
      fileWatcher: DiffStubFileWatcher(),
      searchService: nil,
      cliConfiguration: CLICommandConfiguration(command: "claude", mode: .claude),
      providerKind: .claude,
      diffAvailabilityService: diffService,
      approvalNotificationService: NoOpApprovalNotificationService()
    )

    await viewModel.ensureDiffAvailability(for: "/tmp/project")
    await viewModel.ensureDiffAvailability(for: "/tmp/project", forceRefresh: true)

    let invalidations = await diffService.recordedInvalidations()
    #expect(viewModel.diffAvailabilityStatus(for: "/tmp/project") == .available)
    #expect(invalidations.count == 1)
  }
}
