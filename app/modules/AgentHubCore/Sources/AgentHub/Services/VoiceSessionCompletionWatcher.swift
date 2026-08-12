import Foundation

@MainActor
public protocol VoiceSessionCompletionWatching: AnyObject {
  func watch(sessionId: String, name: String, announceTimeout: Bool)
  func cancel(sessionId: String)
  func cancelAll()
}

extension VoiceSessionCompletionWatching {
  public func watch(sessionId: String, name: String) {
    watch(sessionId: sessionId, name: name, announceTimeout: false)
  }
}

@MainActor
public final class VoiceSessionCompletionWatcher: VoiceSessionCompletionWatching {
  private let executor: any VoiceAgentToolExecuting
  private let onUpdate: @MainActor @Sendable (String) -> Void
  private let onActiveCountChanged: (@MainActor @Sendable (Int) -> Void)?
  private let armingDelay: Duration
  private let completionDebounce: Duration
  private let maximumDuration: Duration
  private var tasks: [String: Task<Void, Never>] = [:]

  public init(
    executor: any VoiceAgentToolExecuting,
    armingDelay: Duration = .seconds(10),
    completionDebounce: Duration = .seconds(2),
    maximumDuration: Duration = .seconds(1_800),
    onActiveCountChanged: (@MainActor @Sendable (Int) -> Void)? = nil,
    onUpdate: @escaping @MainActor @Sendable (String) -> Void
  ) {
    self.executor = executor
    self.armingDelay = armingDelay
    self.completionDebounce = completionDebounce
    self.maximumDuration = maximumDuration
    self.onActiveCountChanged = onActiveCountChanged
    self.onUpdate = onUpdate
  }

  public func watch(
    sessionId: String,
    name: String,
    announceTimeout: Bool
  ) {
    cancel(sessionId: sessionId)
    let stream = executor.completionStream(sessionId: sessionId)
    let armingDelay = self.armingDelay
    let maximumDuration = self.maximumDuration

    tasks[sessionId] = Task { @MainActor [weak self] in
      guard let self else { return }
      let (events, continuation) =
        AsyncStream<CompletionObservationEvent>.makeStream()
      let statusTask = Task {
        for await status in stream {
          continuation.yield(.status(status))
        }
      }
      let armTask = Task {
        try? await Task.sleep(for: armingDelay)
        guard !Task.isCancelled else { return }
        continuation.yield(.armedByTimeout)
      }
      let capTask = Task {
        try? await Task.sleep(for: maximumDuration)
        continuation.finish()
      }
      defer {
        statusTask.cancel()
        armTask.cancel()
        capTask.cancel()
        continuation.finish()
        tasks.removeValue(forKey: sessionId)
        // The single end-of-watch point: report, approval, cap, or cancel
        // all pass through here.
        onActiveCountChanged?(tasks.count)
      }

      var isArmed = false
      var lastStatus: SessionStatus?
      for await event in events {
        guard !Task.isCancelled else { return }
        switch event {
        case .armedByTimeout:
          isArmed = true
          if let lastStatus, lastStatus.isVoiceCompletionState {
            if await reportCompletionIfStable(
              sessionId: sessionId,
              name: name,
              expected: lastStatus
            ) {
              return
            }
          }
        case .status(let status):
          lastStatus = status
          if status.isVoiceWorkingState {
            isArmed = true
          }
          if case .awaitingApproval(let tool) = status {
            onUpdate("\(name) is awaiting approval for \(tool).")
            return
          }
          if isArmed && status.isVoiceCompletionState {
            if await reportCompletionIfStable(
              sessionId: sessionId,
              name: name,
              expected: status
            ) {
              return
            }
          }
        }
      }
      // Reached only when the maximum-duration cap finished the stream —
      // every completion/approval report returns from inside the loop. An
      // explicitly requested watch must not end silently.
      guard announceTimeout, !Task.isCancelled else { return }
      onUpdate("\(name) is still running — I've stopped watching it.")
    }
    onActiveCountChanged?(tasks.count)
  }

  public func cancel(sessionId: String) {
    tasks.removeValue(forKey: sessionId)?.cancel()
    onActiveCountChanged?(tasks.count)
  }

  public func cancelAll() {
    let running = tasks.values
    tasks.removeAll()
    for task in running {
      task.cancel()
    }
    onActiveCountChanged?(tasks.count)
  }

  private func reportCompletionIfStable(
    sessionId: String,
    name: String,
    expected: SessionStatus
  ) async -> Bool {
    try? await Task.sleep(for: completionDebounce)
    guard !Task.isCancelled else { return false }
    let current = executor.sessionStatus(sessionId: sessionId)?.status
    guard current == expected.displayName else { return false }
    let response = await executor.latestResponse(sessionId: sessionId)
    guard !Task.isCancelled else { return false }
    if let text = response?.text, !text.isEmpty {
      onUpdate("""
        \(name) finished. Summarize its response for the user in one or two \
        spoken sentences. Response: \(Self.snippet(text))
        """)
    } else {
      onUpdate("\(name) finished and is ready for you.")
    }
    return true
  }

  private static func snippet(_ text: String, limit: Int = 600) -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > limit else { return normalized }
    return String(normalized.prefix(limit)) + "…"
  }
}

private enum CompletionObservationEvent: Sendable {
  case status(SessionStatus)
  case armedByTimeout
}

private extension SessionStatus {
  var isVoiceWorkingState: Bool {
    switch self {
    case .thinking, .executingTool:
      true
    case .waitingForUser, .awaitingApproval, .idle:
      false
    }
  }

  var isVoiceCompletionState: Bool {
    switch self {
    case .waitingForUser, .idle:
      true
    case .thinking, .executingTool, .awaitingApproval:
      false
    }
  }
}
