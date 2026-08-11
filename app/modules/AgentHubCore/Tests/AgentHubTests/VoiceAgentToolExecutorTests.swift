import Foundation
import Observation
import Testing
@testable import AgentHubCore

@MainActor
@Observable
private final class MockVoiceSessionManager: VoiceSessionManaging {
  let providerKind: SessionProviderKind
  var voiceSessions: [CLISession] = []
  var selectedRepositories: [SelectedRepository] = []
  var sessionCustomNames: [String: String] = [:]
  var monitorStates: [String: SessionMonitorState] = [:]
  var sessionStatuses: [String: SessionStatus] = [:]
  var pendingHubSessions: [PendingHubSession] = []
  var resolvedPendingSessions: [UUID: String] = [:]
  var lastCreatedPendingId: UUID?
  var activeTerminalResult = false
  var calls: [String] = []
  private(set) var shownPrompts: [String] = []
  private(set) var launched: [(WorktreeBranch, String?)] = []

  init(providerKind: SessionProviderKind) {
    self.providerKind = providerKind
  }

  func sendPromptToActiveTerminal(
    forKey key: String,
    prompt: String
  ) -> Bool {
    calls.append("send")
    return activeTerminalResult
  }

  func showTerminalWithPrompt(for session: CLISession, prompt: String) {
    calls.append("show")
    shownPrompts.append(prompt)
  }

  func focusTerminal(forKey key: String) {
    calls.append("focus")
  }

  func voiceStartNewSessionInHub(
    _ worktree: WorktreeBranch,
    initialPrompt: String?
  ) {
    launched.append((worktree, initialPrompt))
    let pending = PendingHubSession(worktree: worktree)
    pendingHubSessions.append(pending)
    lastCreatedPendingId = pending.id
  }
}

private struct StubTranscriptReader: VoiceSessionTranscriptReading {
  let textsByPath: [String: String]

  func latestAssistantText(
    atPath path: String,
    provider: SessionProviderKind
  ) async -> String? {
    textsByPath[path]
  }
}

@MainActor
private final class FixedVoiceTargetResolver: VoiceSessionTargetResolving {
  var target: VoiceSessionTarget?

  func resolve(manualSessionId: String?) -> VoiceSessionTarget? {
    target
  }

  func candidates() -> [VoiceSessionTarget] {
    target.map { [$0] } ?? []
  }
}

@MainActor
struct VoiceAgentToolExecutorTests {
  @Test
  func listSessionsProducesCodableSummaryAndResolvedTarget() throws {
    let target = VoiceSessionTarget(
      sessionId: "s1",
      provider: .claude,
      name: "Build",
      projectPath: "/repo",
      lastActivityAt: Date()
    )
    let (executor, claude, _) = makeExecutor(target: target)
    claude.voiceSessions = [session(id: "s1")]
    claude.sessionCustomNames["s1"] = "Build"
    claude.monitorStates["s1"] = SessionMonitorState(status: .thinking)

    let summary = executor.listSessions()
    let encoded = try JSONEncoder().encode(summary)
    let decoded = try JSONDecoder().decode(
      VoiceSessionsSummary.self,
      from: encoded
    )

    #expect(decoded == summary)
    #expect(summary.sessions.first?.name == "Build")
    #expect(summary.sessions.first?.status == "Working")
    #expect(summary.targetSessionId == "s1")
  }

  @Test
  func sendsToMountedTerminalBeforeFallingBack() {
    let (executor, claude, _) = makeExecutor()
    claude.voiceSessions = [session(id: "s1")]

    let fallback = executor.sendPrompt(sessionId: "s1", prompt: "test")
    #expect(fallback.status == "accepted")
    #expect(!fallback.usedExistingTerminal)
    #expect(claude.calls == ["send", "show"])

    claude.calls.removeAll()
    claude.activeTerminalResult = true
    let mounted = executor.sendPrompt(sessionId: "s1", prompt: "again")
    #expect(mounted.usedExistingTerminal)
    #expect(claude.calls == ["send"])
  }

  @Test
  func statusTruncatesAndLimitsRecentActivities() {
    let (executor, claude, _) = makeExecutor()
    claude.voiceSessions = [session(id: "s1")]
    claude.monitorStates["s1"] = SessionMonitorState(
      status: .executingTool(name: "Bash"),
      currentTool: "Bash",
      inputTokens: 100_000,
      recentActivities: (0..<5).map { index in
        ActivityEntry(
          timestamp: Date(timeIntervalSince1970: Double(index)),
          type: .assistantMessage,
          description: String(repeating: "\(index)", count: 250)
        )
      }
    )

    let detail = executor.sessionStatus(sessionId: "s1")

    #expect(detail?.recentActivities.count == 3)
    #expect(detail?.recentActivities.allSatisfy { $0.description.count == 203 } == true)
    #expect(detail?.contextUsagePercent == 50)
  }

  @Test
  func launchesOnlyRegisteredWorktreesAndReturnsPendingID() {
    let (executor, _, codex) = makeExecutor()
    let worktree = WorktreeBranch(
      name: "feature",
      path: "/repo-feature",
      isWorktree: true
    )
    codex.selectedRepositories = [
      SelectedRepository(path: "/repo", worktrees: [worktree])
    ]

    let result = executor.launchSession(
      worktreePath: "/repo-feature",
      provider: .codex,
      prompt: "Build it"
    )

    #expect(result.status == "accepted")
    #expect(result.pendingSessionId != nil)
    #expect(codex.launched.first?.0 == worktree)
    #expect(codex.launched.first?.1 == "Build it")

    let missing = executor.launchSession(
      worktreePath: "/missing",
      provider: .codex,
      prompt: nil
    )
    #expect(missing.status == "not_found")
  }

  @Test
  func pendingLaunchCompletionStreamFollowsResolvedSession() async {
    let (executor, _, codex) = makeExecutor()
    let worktree = WorktreeBranch(
      name: "feature",
      path: "/repo-feature",
      isWorktree: true
    )
    codex.selectedRepositories = [
      SelectedRepository(path: "/repo", worktrees: [worktree])
    ]
    let result = executor.launchSession(
      worktreePath: worktree.path,
      provider: .codex,
      prompt: nil
    )
    guard let pendingID = result.pendingSessionId,
          let pendingUUID = UUID(uuidString: pendingID) else {
      Issue.record("Expected a valid pending session ID")
      return
    }
    let stream = executor.completionStream(sessionId: pendingID)
    var iterator = stream.makeAsyncIterator()

    codex.voiceSessions = [session(id: "resolved-session")]
    codex.resolvedPendingSessions[pendingUUID] = "resolved-session"
    codex.sessionStatuses["resolved-session"] = .thinking

    #expect(await iterator.next() == .thinking)
    #expect(executor.sessionStatus(sessionId: pendingID)?.sessionId == "resolved-session")
  }

  @Test
  func approvalResponsesUseEstablishedTerminalChoices() {
    let (executor, claude, _) = makeExecutor()
    claude.voiceSessions = [session(id: "s1")]
    claude.monitorStates["s1"] = SessionMonitorState(
      status: .awaitingApproval(tool: "Bash"),
      pendingToolUse: PendingToolUse(
        toolName: "Bash",
        toolUseId: "tool-1",
        timestamp: Date(),
        input: "Run tests"
      )
    )

    _ = executor.respondToApproval(sessionId: "s1", approve: true)
    _ = executor.respondToApproval(sessionId: "s1", approve: false)

    #expect(claude.shownPrompts == ["1", "3"])
  }

  @Test
  func latestResponseReadsTranscriptForExplicitSession() async {
    let reader = StubTranscriptReader(
      textsByPath: ["/tmp/s1.jsonl": "Here is what I found."]
    )
    let (executor, claude, _) = makeExecutor(target: nil, transcriptReader: reader)
    claude.voiceSessions = [
      session(id: "s1", sessionFilePath: "/tmp/s1.jsonl")
    ]
    claude.sessionCustomNames["s1"] = "Build"

    let response = await executor.latestResponse(sessionId: "s1")

    #expect(response?.sessionId == "s1")
    #expect(response?.name == "Build")
    #expect(response?.text == "Here is what I found.")
  }

  @Test
  func latestResponseFallsBackToTargetSession() async {
    let reader = StubTranscriptReader(
      textsByPath: ["/tmp/s1.jsonl": "Target session answer."]
    )
    let target = VoiceSessionTarget(
      sessionId: "s1",
      provider: .claude,
      name: "Build",
      projectPath: "/repo",
      lastActivityAt: Date()
    )
    let (executor, claude, _) = makeExecutor(
      target: target,
      transcriptReader: reader
    )
    claude.voiceSessions = [
      session(id: "s1", sessionFilePath: "/tmp/s1.jsonl")
    ]

    let response = await executor.latestResponse(sessionId: nil)

    #expect(response?.sessionId == "s1")
    #expect(response?.text == "Target session answer.")
  }

  @Test
  func latestResponseIsNilWithoutTranscriptText() async {
    let (executor, claude, _) = makeExecutor(target: nil)
    claude.voiceSessions = [
      session(id: "s1", sessionFilePath: "/tmp/s1.jsonl")
    ]

    #expect(await executor.latestResponse(sessionId: "s1") == nil)
    #expect(await executor.latestResponse(sessionId: "missing") == nil)
    #expect(await executor.latestResponse(sessionId: nil) == nil)
  }

  private func makeExecutor() -> (
    VoiceAgentToolExecutor,
    MockVoiceSessionManager,
    MockVoiceSessionManager
  ) {
    makeExecutor(target: nil)
  }

  private func makeExecutor(
    target: VoiceSessionTarget?,
    transcriptReader: any VoiceSessionTranscriptReading =
      StubTranscriptReader(textsByPath: [:])
  ) -> (
    VoiceAgentToolExecutor,
    MockVoiceSessionManager,
    MockVoiceSessionManager
  ) {
    let claude = MockVoiceSessionManager(providerKind: .claude)
    let codex = MockVoiceSessionManager(providerKind: .codex)
    let resolver = FixedVoiceTargetResolver()
    resolver.target = target
    return (
      VoiceAgentToolExecutor(
        claudeViewModel: claude,
        codexViewModel: codex,
        selectionRouter: GlobalSessionSelectionRouter(),
        targetResolver: resolver,
        transcriptReader: transcriptReader
      ),
      claude,
      codex
    )
  }

  private func session(
    id: String,
    sessionFilePath: String? = nil
  ) -> CLISession {
    CLISession(
      id: id,
      projectPath: "/repo",
      lastActivityAt: Date(),
      isActive: true,
      sessionFilePath: sessionFilePath
    )
  }
}
