import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionNameRequestMonitor")
struct SessionNameRequestMonitorTests {
  @Test("Monitor handles queued request and removes it")
  func monitorHandlesQueuedRequestAndRemovesIt() async throws {
    let directory = try temporarySessionNameMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SessionNameRequestQueue(directoryURL: directory)
    let request = SessionNameRequest(
      id: "name-1",
      name: "Session Naming",
      sourceProvider: .codex,
      sourceSessionId: "session-1",
      sourceProcessId: 42
    )
    try queue.enqueue(request)

    let recorder = SessionNameRequestRecorder()
    let monitor = SessionNameRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { queued in
      await recorder.record(queued.request)
    }

    await waitForSessionNameMonitorCondition {
      await recorder.requests() == [request]
        && ((try? queue.pendingRequests().isEmpty) == true)
    }
    await monitor.stop()
  }

  @Test("Monitor marks failed request out of pending queue")
  func monitorMarksFailedRequestOutOfPendingQueue() async throws {
    let directory = try temporarySessionNameMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SessionNameRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(SessionNameRequest(
      id: "name-1",
      createdAt: Date.now.addingTimeInterval(-11),
      name: "Session Naming",
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 42
    ))

    let monitor = SessionNameRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { _ in
      throw SessionNameRequestHandlingError.sessionUnavailable
    }

    await waitForSessionNameMonitorCondition {
      let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
      return ((try? queue.pendingRequests().isEmpty) == true)
        && FileManager.default.fileExists(atPath: failedURL.path)
    }
    await monitor.stop()
  }

  @Test("Monitor retries a fresh request while its session is being discovered")
  func monitorRetriesFreshUnavailableSession() async throws {
    let directory = try temporarySessionNameMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SessionNameRequestQueue(directoryURL: directory)
    try queue.enqueue(SessionNameRequest(
      id: "name-1",
      name: "Session Naming",
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 42
    ))

    let recorder = SessionNameRequestRetryRecorder()
    let monitor = SessionNameRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { _ in
      let attempt = await recorder.recordAttempt()
      if attempt == 1 {
        throw SessionNameRequestHandlingError.sessionUnavailable
      }
    }

    await waitForSessionNameMonitorCondition {
      await recorder.attemptCount() == 2
        && ((try? queue.pendingRequests().isEmpty) == true)
    }
    await monitor.stop()
  }
}

private actor SessionNameRequestRecorder {
  private var recordedRequests: [SessionNameRequest] = []

  func record(_ request: SessionNameRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [SessionNameRequest] {
    recordedRequests
  }
}

private actor SessionNameRequestRetryRecorder {
  private var attempts = 0

  func recordAttempt() -> Int {
    attempts += 1
    return attempts
  }

  func attemptCount() -> Int {
    attempts
  }
}

private func waitForSessionNameMonitorCondition(
  timeout: Duration = .seconds(2),
  condition: @escaping () async -> Bool
) async {
  let start = ContinuousClock.now
  while !(await condition()), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(await condition())
}

private func temporarySessionNameMonitorRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-session-name-monitor-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
