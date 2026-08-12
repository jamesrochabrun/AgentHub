import Foundation
import Testing
@testable import AgentHubCore

@MainActor
private final class CompletionWatcherExecutor: VoiceAgentToolExecuting {
  private let stream: AsyncStream<SessionStatus>
  private let continuation: AsyncStream<SessionStatus>.Continuation
  var currentStatus: SessionStatus?

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func yield(_ status: SessionStatus) {
    currentStatus = status
    continuation.yield(status)
  }

  func listSessions() -> VoiceSessionsSummary {
    .init(sessions: [], targetSessionId: nil)
  }

  func sessionStatus(
    sessionId: String,
    activityLimit: Int
  ) -> VoiceSessionStatusDetail? {
    guard let currentStatus else { return nil }
    return .init(
      sessionId: sessionId,
      provider: .claude,
      name: "Test",
      status: currentStatus.displayName,
      currentTool: nil,
      contextUsagePercent: nil,
      pendingApproval: nil,
      recentActivities: []
    )
  }

  func sessionHistory(
    sessionId: String?,
    turnLimit: Int
  ) async -> VoiceSessionHistory? {
    nil
  }

  func sendPrompt(
    sessionId: String,
    prompt: String
  ) -> VoicePromptDeliveryResult {
    .init(status: "accepted", sessionId: sessionId, usedExistingTerminal: true)
  }

  func focusSession(sessionId: String) -> Bool {
    true
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
      pendingSessionId: nil
    )
  }

  func listWorktrees() -> VoiceWorktreeInventory {
    .init(repositories: [])
  }

  func createWorktreeTasks(
    repositoryPath: String?,
    tasks: [VoiceWorktreeTaskSpec]
  ) async -> VoiceWorktreeTaskBatchResult {
    .init(
      status: "accepted",
      message: nil,
      repositoryPath: repositoryPath ?? "",
      launched: [],
      failures: []
    )
  }

  func pendingApproval(sessionId: String) -> VoicePendingApproval? {
    nil
  }

  func respondToApproval(
    sessionId: String,
    approve: Bool
  ) -> VoiceApprovalResponseResult {
    .init(
      status: "accepted",
      sessionId: sessionId,
      decision: approve ? "approve" : "deny"
    )
  }

  func completionStream(sessionId: String) -> AsyncStream<SessionStatus> {
    stream
  }

  var latestResponseText: String?

  func latestResponse(sessionId: String?) async -> VoiceLatestResponse? {
    guard let latestResponseText, let sessionId else { return nil }
    return .init(
      sessionId: sessionId,
      provider: .claude,
      name: "Test",
      text: latestResponseText
    )
  }
}

@MainActor
struct VoiceSessionCompletionWatcherTests {
  @Test
  func armsOnWorkingStatusAndDebouncesCompletion() async {
    let executor = CompletionWatcherExecutor()
    var updates: [String] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .milliseconds(5),
      maximumDuration: .seconds(1)
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    executor.yield(.thinking)
    executor.yield(.idle)
    await waitUntil { !updates.isEmpty }

    #expect(updates == ["Build finished and is ready for you."])
  }

  @Test
  func completionAnnouncementIncludesLatestResponse() async {
    let executor = CompletionWatcherExecutor()
    executor.latestResponseText = "All 23 tests passed."
    var updates: [String] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .milliseconds(5),
      maximumDuration: .seconds(1)
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    executor.yield(.thinking)
    executor.yield(.idle)
    await waitUntil { !updates.isEmpty }

    #expect(updates.count == 1)
    #expect(updates[0].contains("Build finished."))
    #expect(updates[0].contains("All 23 tests passed."))
  }

  @Test
  func reportsActiveWatchCountAcrossTheWatchLifecycle() async {
    let executor = CompletionWatcherExecutor()
    var counts: [Int] = []
    var updates: [String] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .milliseconds(5),
      maximumDuration: .seconds(1),
      onActiveCountChanged: { counts.append($0) }
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    #expect(counts.last == 1)

    executor.yield(.thinking)
    executor.yield(.idle)
    await waitUntil { !updates.isEmpty }
    await waitUntil { counts.last == 0 }

    #expect(counts.last == 0)
  }

  @Test
  func cancelAllReportsZeroActiveWatches() async {
    let executor = CompletionWatcherExecutor()
    var counts: [Int] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .seconds(1),
      maximumDuration: .seconds(1),
      onActiveCountChanged: { counts.append($0) }
    ) { _ in }

    watcher.watch(sessionId: "session-1", name: "Build")
    #expect(counts.last == 1)

    watcher.cancelAll()
    #expect(counts.last == 0)
  }

  @Test
  func explicitWatchAnnouncesTimeoutInsteadOfEndingSilently() async {
    let executor = CompletionWatcherExecutor()
    var updates: [String] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .seconds(1),
      maximumDuration: .milliseconds(20)
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build", announceTimeout: true)
    executor.yield(.thinking)
    await waitUntil { !updates.isEmpty }

    #expect(updates == ["Build is still running — I've stopped watching it."])
  }

  @Test
  func implicitWatchStillTimesOutSilently() async {
    let executor = CompletionWatcherExecutor()
    var updates: [String] = []
    var counts: [Int] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .seconds(1),
      maximumDuration: .milliseconds(20),
      onActiveCountChanged: { counts.append($0) }
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    executor.yield(.thinking)
    await waitUntil { counts.last == 0 }

    #expect(updates.isEmpty)
  }

  @Test
  func reportsApprovalImmediately() async {
    let executor = CompletionWatcherExecutor()
    var updates: [String] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .seconds(1),
      maximumDuration: .seconds(1)
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    executor.yield(.awaitingApproval(tool: "Bash"))
    await waitUntil { !updates.isEmpty }

    #expect(updates == ["Build is awaiting approval for Bash."])
  }

  @Test
  func keepsWatchingWhenDebouncedStatusIsNoLongerStable() async {
    let executor = CompletionWatcherExecutor()
    var updates: [String] = []
    let watcher = VoiceSessionCompletionWatcher(
      executor: executor,
      armingDelay: .seconds(1),
      completionDebounce: .milliseconds(20),
      maximumDuration: .seconds(1)
    ) {
      updates.append($0)
    }

    watcher.watch(sessionId: "session-1", name: "Build")
    executor.yield(.thinking)
    executor.yield(.idle)
    executor.currentStatus = .thinking
    try? await Task.sleep(for: .milliseconds(30))
    executor.yield(.waitingForUser)
    await waitUntil { !updates.isEmpty }

    #expect(updates == ["Build finished and is ready for you."])
  }

  private func waitUntil(
    _ predicate: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<200 {
      if predicate() {
        return
      }
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}
