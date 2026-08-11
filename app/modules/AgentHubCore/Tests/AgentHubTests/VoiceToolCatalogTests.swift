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

  func sessionStatus(sessionId: String) -> VoiceSessionStatusDetail? {
    details[sessionId]
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
        "send_prompt",
        "focus_session",
        "launch_session",
        "approve_pending_tool",
        "list_displays",
        "capture_screen",
      ]
    )
    #expect(
      tools.first(where: { $0.name == "approve_pending_tool" })?
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
