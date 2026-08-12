import AgentHubVoice
import Foundation
import Testing
@testable import AgentHubCore

@MainActor
private final class MockVoiceToolExecutor: VoiceAgentToolExecuting {
  var sessions = VoiceSessionsSummary(sessions: [], targetSessionId: nil)
  var details: [String: VoiceSessionStatusDetail] = [:]
  var pending: [String: VoicePendingApproval] = [:]
  private(set) var approvalResponses: [(String, Bool)] = []
  private(set) var completionStreamSessionIds: [String] = []

  func listSessions() -> VoiceSessionsSummary {
    sessions
  }

  private(set) var statusRequests: [(String, Int)] = []

  func sessionStatus(
    sessionId: String,
    activityLimit: Int
  ) -> VoiceSessionStatusDetail? {
    statusRequests.append((sessionId, activityLimit))
    return details[sessionId]
  }

  var histories: [String: VoiceSessionHistory] = [:]
  var defaultHistory: VoiceSessionHistory?
  private(set) var historyRequests: [(String?, Int)] = []

  func sessionHistory(
    sessionId: String?,
    turnLimit: Int
  ) async -> VoiceSessionHistory? {
    historyRequests.append((sessionId, turnLimit))
    guard let sessionId else { return defaultHistory }
    return histories[sessionId]
  }

  func sendPrompt(
    sessionId: String,
    prompt: String
  ) -> VoicePromptDeliveryResult {
    .init(status: "accepted", sessionId: sessionId, usedExistingTerminal: true)
  }

  func focusSession(sessionId: String) -> Bool {
    details[sessionId] != nil
  }

  func launchSession(
    worktreePath: String,
    provider: SessionProviderKind,
    prompt: String?
  ) -> VoiceLaunchResult {
    .init(
      status: "accepted",
      provider: provider,
      worktreePath: worktreePath,
      pendingSessionId: "pending"
    )
  }

  var inventory = VoiceWorktreeInventory(repositories: [])

  func listWorktrees() -> VoiceWorktreeInventory {
    inventory
  }

  var taskBatchResult = VoiceWorktreeTaskBatchResult(
    status: "accepted",
    message: nil,
    repositoryPath: "/repo",
    launched: [],
    failures: []
  )
  private(set) var createdTaskRequests: [(String?, [VoiceWorktreeTaskSpec])] = []

  func createWorktreeTasks(
    repositoryPath: String?,
    tasks: [VoiceWorktreeTaskSpec]
  ) async -> VoiceWorktreeTaskBatchResult {
    createdTaskRequests.append((repositoryPath, tasks))
    return taskBatchResult
  }

  func pendingApproval(sessionId: String) -> VoicePendingApproval? {
    pending[sessionId]
  }

  func respondToApproval(
    sessionId: String,
    approve: Bool
  ) -> VoiceApprovalResponseResult {
    approvalResponses.append((sessionId, approve))
    return .init(
      status: "accepted",
      sessionId: sessionId,
      decision: approve ? "approve" : "deny"
    )
  }

  func completionStream(
    sessionId: String
  ) -> AsyncStream<SessionStatus> {
    completionStreamSessionIds.append(sessionId)
    return AsyncStream { $0.finish() }
  }

  var latestResponses: [String: VoiceLatestResponse] = [:]
  var defaultLatestResponse: VoiceLatestResponse?
  private(set) var latestResponseRequests: [String?] = []

  func latestResponse(sessionId: String?) async -> VoiceLatestResponse? {
    latestResponseRequests.append(sessionId)
    guard let sessionId else { return defaultLatestResponse }
    return latestResponses[sessionId]
  }
}

private struct MockScreenCapture: VoiceScreenCapturing {
  var displays: [VoiceCaptureDisplay] = []
  var result: VoiceScreenCaptureResult?

  @MainActor func hasPermission() -> Bool { true }
  @MainActor func requestPermission() -> Bool { true }

  func listDisplays() async throws -> [VoiceCaptureDisplay] {
    displays
  }

  func capture(
    displayIndex: Int?,
    region: VoiceCaptureRegion?
  ) async throws -> VoiceScreenCaptureResult {
    guard let result else {
      throw VoiceScreenCaptureError.permissionDenied
    }
    return result
  }
}

@MainActor
struct VoiceToolCatalogTests {
  @Test
  func exposesAllSchemasAndDisablesApprovalRetry() {
    let tools = VoiceToolCatalog(
      executor: MockVoiceToolExecutor(),
      screenCapture: MockScreenCapture(),
      isScreenCaptureEnabled: { true },
      onBackgroundUpdate: { _ in }
    ).makeTools()

    #expect(
      Set(tools.map(\.name)) == [
        "list_sessions",
        "get_session_status",
        "read_session_response",
        "read_session_history",
        "send_prompt",
        "watch_session",
        "stop_watching",
        "focus_session",
        "list_worktrees",
        "launch_session",
        "create_worktree_tasks",
        "approve_pending_tool",
        "list_displays",
        "capture_screen",
      ]
    )
    #expect(
      tools.first(where: { $0.name == "approve_pending_tool" })?
        .allowsAutomaticRetry == false
    )
    #expect(
      tools.first(where: { $0.name == "create_worktree_tasks" })?
        .allowsAutomaticRetry == false
    )
    #expect(tools.allSatisfy { $0.parameters["type"] != nil })
  }

  @Test
  func screenCaptureToolsAreOmittedWhenDisabled() {
    let tools = VoiceToolCatalog(
      executor: MockVoiceToolExecutor(),
      screenCapture: MockScreenCapture(),
      isScreenCaptureEnabled: { false },
      onBackgroundUpdate: { _ in }
    ).makeTools()

    #expect(!tools.contains { $0.name == "capture_screen" })
    #expect(!tools.contains { $0.name == "list_displays" })
  }

  @Test
  func captureScreenReturnsPathAndListsDisplays() async throws {
    let display = VoiceCaptureDisplay(
      index: 2,
      name: "Studio Display",
      width: 2_560,
      height: 1_440,
      isMain: false
    )
    var capture = MockScreenCapture()
    capture.displays = [display]
    capture.result = VoiceScreenCaptureResult(
      path: "/tmp/shot.png",
      display: display,
      region: nil
    )
    let catalog = VoiceToolCatalog(
      executor: MockVoiceToolExecutor(),
      screenCapture: capture,
      isScreenCaptureEnabled: { true },
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let captured = await registry.execute(
      name: "capture_screen",
      arguments: #"{"display_index":2}"#
    )
    #expect(try status(captured) == "captured")
    #expect(captured.contains("shot.png"))

    let displays = await registry.execute(
      name: "list_displays",
      arguments: "{}"
    )
    #expect(displays.contains("Studio Display"))
  }

  @Test
  func captureScreenSurfacesErrorsAsToolResults() async throws {
    let catalog = VoiceToolCatalog(
      executor: MockVoiceToolExecutor(),
      screenCapture: MockScreenCapture(),
      isScreenCaptureEnabled: { true },
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let result = await registry.execute(
      name: "capture_screen",
      arguments: "{}"
    )
    #expect(try status(result) == "error")
    #expect(result.contains("Screen Recording"))
  }

  @Test
  func readSessionResponseReturnsTextAndDefaultsToTargetSession() async throws {
    let executor = MockVoiceToolExecutor()
    executor.latestResponses["claude-1"] = .init(
      sessionId: "claude-1",
      provider: .claude,
      name: "Build",
      text: "All tests passed."
    )
    executor.defaultLatestResponse = .init(
      sessionId: "target-1",
      provider: .claude,
      name: "Target",
      text: "Target answer."
    )
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let explicit = await registry.execute(
      name: "read_session_response",
      arguments: #"{"session_id":"claude-1"}"#
    )
    #expect(explicit.contains("All tests passed."))

    let defaulted = await registry.execute(
      name: "read_session_response",
      arguments: "{}"
    )
    #expect(defaulted.contains("Target answer."))
    #expect(executor.latestResponseRequests == ["claude-1", nil])

    executor.defaultLatestResponse = nil
    let missing = await registry.execute(
      name: "read_session_response",
      arguments: "{}"
    )
    #expect(try status(missing) == "not_found")
  }

  @Test
  func readSessionHistoryDefaultsToTargetAndSixTurns() async throws {
    let executor = MockVoiceToolExecutor()
    executor.histories["claude-1"] = VoiceSessionHistory(
      sessionId: "claude-1",
      provider: .claude,
      name: "Build",
      turns: [
        VoiceTranscriptTurn(role: "user", text: "run the tests"),
        VoiceTranscriptTurn(role: "assistant", text: "All 23 passed."),
      ]
    )
    executor.defaultHistory = VoiceSessionHistory(
      sessionId: "target-1",
      provider: .codex,
      name: "Target",
      turns: [VoiceTranscriptTurn(role: "assistant", text: "Target turn.")]
    )
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let explicit = await registry.execute(
      name: "read_session_history",
      arguments: #"{"session_id":"claude-1","turn_limit":10}"#
    )
    #expect(explicit.contains("run the tests"))
    #expect(explicit.contains("All 23 passed."))

    let defaulted = await registry.execute(
      name: "read_session_history",
      arguments: "{}"
    )
    #expect(defaulted.contains("Target turn."))
    #expect(executor.historyRequests.map(\.0) == ["claude-1", nil])
    #expect(executor.historyRequests.map(\.1) == [10, 6])

    executor.defaultHistory = nil
    let missing = await registry.execute(
      name: "read_session_history",
      arguments: "{}"
    )
    #expect(try status(missing) == "not_found")
  }

  @Test
  func sessionStatusPassesActivityLimitAndDefaultsToThree() async throws {
    let executor = MockVoiceToolExecutor()
    executor.details["claude-1"] = detail(
      sessionId: "claude-1",
      provider: .claude
    )
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    _ = await registry.execute(
      name: "get_session_status",
      arguments: #"{"session_id":"claude-1"}"#
    )
    _ = await registry.execute(
      name: "get_session_status",
      arguments: #"{"session_id":"claude-1","activity_limit":12}"#
    )
    let statusToolRequests = executor.statusRequests.filter { $0.0 == "claude-1" }
    #expect(statusToolRequests.map(\.1) == [3, 12])
  }

  @Test
  func watchSessionArmsAWatcherWithoutSendingAnything() async throws {
    let executor = MockVoiceToolExecutor()
    executor.details["claude-1"] = detail(
      sessionId: "claude-1",
      provider: .claude
    )
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let missing = await registry.execute(
      name: "watch_session",
      arguments: #"{"session_id":"unknown"}"#
    )
    #expect(try status(missing) == "not_found")
    #expect(executor.completionStreamSessionIds.isEmpty)

    let watching = await registry.execute(
      name: "watch_session",
      arguments: #"{"session_id":"claude-1"}"#
    )
    #expect(try status(watching) == "watching")
    #expect(executor.completionStreamSessionIds == ["claude-1"])

    let stopped = await registry.execute(
      name: "stop_watching",
      arguments: "{}"
    )
    #expect(try status(stopped) == "stopped")
  }

  @Test
  func approvalRequiresConfirmationThenInjectsDecision() async throws {
    let executor = MockVoiceToolExecutor()
    executor.details["claude-1"] = detail(
      sessionId: "claude-1",
      provider: .claude
    )
    executor.pending["claude-1"] = pending(
      sessionId: "claude-1",
      toolUseId: "tool-1"
    )
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let first = await registry.execute(
      name: "approve_pending_tool",
      arguments: #"{"session_id":"claude-1","decision":"approve"}"#
    )
    #expect(try status(first) == "confirmation_required")
    #expect(executor.approvalResponses.isEmpty)

    let second = await registry.execute(
      name: "approve_pending_tool",
      arguments: #"{"session_id":"claude-1","decision":"approve","confirmed":true}"#
    )
    #expect(try status(second) == "accepted")
    #expect(executor.approvalResponses.count == 1)
    #expect(executor.approvalResponses.first?.0 == "claude-1")
    #expect(executor.approvalResponses.first?.1 == true)
  }

  @Test
  func changedApprovalIsStaleAndCodexIsRejected() async throws {
    let executor = MockVoiceToolExecutor()
    executor.details["claude-1"] = detail(
      sessionId: "claude-1",
      provider: .claude
    )
    executor.pending["claude-1"] = pending(
      sessionId: "claude-1",
      toolUseId: "tool-1"
    )
    executor.details["codex-1"] = detail(
      sessionId: "codex-1",
      provider: .codex
    )
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    _ = await registry.execute(
      name: "approve_pending_tool",
      arguments: #"{"session_id":"claude-1","decision":"deny"}"#
    )
    executor.pending["claude-1"] = pending(
      sessionId: "claude-1",
      toolUseId: "tool-2"
    )
    let stale = await registry.execute(
      name: "approve_pending_tool",
      arguments: #"{"session_id":"claude-1","decision":"deny","confirmed":true}"#
    )
    #expect(try status(stale) == "stale")

    let codex = await registry.execute(
      name: "approve_pending_tool",
      arguments: #"{"session_id":"codex-1","decision":"approve"}"#
    )
    #expect(try status(codex) == "rejected")
  }

  @Test
  func listWorktreesEncodesInventory() async {
    let executor = MockVoiceToolExecutor()
    executor.inventory = VoiceWorktreeInventory(repositories: [
      VoiceRepositorySummary(
        name: "Repo",
        path: "/repo",
        worktrees: [
          VoiceWorktreeSummary(
            name: "main",
            path: "/repo",
            isWorktree: false,
            sessionCount: 2
          ),
        ]
      ),
    ])
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let result = await registry.execute(
      name: "list_worktrees",
      arguments: "{}"
    )
    #expect(result.contains(#""path":"\/repo""#) || result.contains(#""path":"/repo""#))
    #expect(result.contains(#""session_count":2"#))
  }

  @Test
  func createWorktreeTasksAppliesDefaultProviderAndWatchesLaunches() async throws {
    let executor = MockVoiceToolExecutor()
    executor.taskBatchResult = VoiceWorktreeTaskBatchResult(
      status: "accepted",
      message: nil,
      repositoryPath: "/repo",
      launched: [
        VoiceWorktreeTaskLaunch(
          branch: "task-a",
          provider: .codex,
          worktreePath: "/repo-task-a",
          pendingSessionId: "pending-1"
        ),
        VoiceWorktreeTaskLaunch(
          branch: "task-b",
          provider: .claude,
          worktreePath: "/repo-task-b",
          pendingSessionId: nil
        ),
      ],
      failures: []
    )
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let result = await registry.execute(
      name: "create_worktree_tasks",
      arguments: """
        {"repository_path":"/repo","provider":"codex","tasks":[\
        {"branch":"task-a","prompt":"Do A"},\
        {"branch":"task-b","prompt":"Do B","provider":"claude"}]}
        """
    )

    #expect(try status(result) == "accepted")
    let request = try #require(executor.createdTaskRequests.first)
    #expect(request.0 == "/repo")
    #expect(request.1.map(\.branch) == ["task-a", "task-b"])
    #expect(request.1.map(\.provider) == [.codex, .claude])
    #expect(executor.completionStreamSessionIds == ["pending-1"])
  }

  @Test
  func createWorktreeTasksOmittedRepositoryDefaultsToTargetSession() async throws {
    let executor = MockVoiceToolExecutor()
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let result = await registry.execute(
      name: "create_worktree_tasks",
      arguments: #"{"tasks":[{"branch":"task-a","prompt":"Do A"}]}"#
    )

    #expect(try status(result) == "accepted")
    let request = try #require(executor.createdTaskRequests.first)
    #expect(request.0 == nil)
    #expect(request.1.map(\.provider) == [.claude])
  }

  @Test
  func createWorktreeTasksRejectsInvalidArguments() async throws {
    let executor = MockVoiceToolExecutor()
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let emptyTasks = await registry.execute(
      name: "create_worktree_tasks",
      arguments: #"{"repository_path":"/repo","tasks":[]}"#
    )
    #expect(try status(emptyTasks) == "error")

    let blankPrompt = await registry.execute(
      name: "create_worktree_tasks",
      arguments: #"{"repository_path":"/repo","tasks":[{"branch":"a","prompt":"  "}]}"#
    )
    #expect(try status(blankPrompt) == "error")

    let badProvider = await registry.execute(
      name: "create_worktree_tasks",
      arguments: #"{"repository_path":"/repo","tasks":[{"branch":"a","prompt":"Do","provider":"gpt"}]}"#
    )
    #expect(try status(badProvider) == "error")
    #expect(executor.createdTaskRequests.isEmpty)
  }

  @Test
  func launchStartsCompletionWatchForPendingSession() async {
    let executor = MockVoiceToolExecutor()
    let catalog = VoiceToolCatalog(
      executor: executor,
      onBackgroundUpdate: { _ in }
    )
    let registry = VoiceToolRegistry(tools: catalog.makeTools())

    let result = await registry.execute(
      name: "launch_session",
      arguments: """
        {"worktree_path":"/repo","provider":"claude","prompt":"Start"}
        """
    )

    #expect(result.contains(#""status":"accepted""#))
    #expect(executor.completionStreamSessionIds == ["pending"])
  }

  private func status(_ json: String) throws -> String? {
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    )
    return object["status"] as? String
  }

  private func detail(
    sessionId: String,
    provider: SessionProviderKind
  ) -> VoiceSessionStatusDetail {
    .init(
      sessionId: sessionId,
      provider: provider,
      name: sessionId,
      status: "Ready",
      currentTool: nil,
      contextUsagePercent: nil,
      pendingApproval: nil,
      recentActivities: []
    )
  }

  private func pending(
    sessionId: String,
    toolUseId: String
  ) -> VoicePendingApproval {
    .init(
      sessionId: sessionId,
      provider: .claude,
      toolName: "Bash",
      toolUseId: toolUseId,
      detail: "Run tests"
    )
  }
}
