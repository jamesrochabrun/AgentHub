import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@Suite("SimulatorRunRequestMonitor")
struct SimulatorRunRequestMonitorTests {
  @Test("Monitor handles queued simulator request and removes it")
  func monitorHandlesQueuedRequestAndRemovesIt() async throws {
    let directory = try temporarySimulatorMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SimulatorRunRequestQueue(directoryURL: directory)
    let request = SimulatorRunRequest(
      id: "sim-run-1",
      projectPath: "/tmp/App",
      udid: "UDID-1",
      sourceProvider: .codex,
      sourceSessionId: "session-1"
    )
    try queue.enqueue(request)

    let recorder = SimulatorRunRequestRecorder()
    let monitor = SimulatorRunRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { queued in
      await recorder.record(queued.request)
    }

    await waitForSimulatorMonitorCondition {
      await recorder.requests() == [request]
        && ((try? queue.pendingRequests().isEmpty) == true)
    }
    await monitor.stop()
  }

  @Test("Monitor marks failed simulator request out of pending queue")
  func monitorMarksFailedRequestOutOfPendingQueue() async throws {
    let directory = try temporarySimulatorMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SimulatorRunRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(SimulatorRunRequest(
      id: "sim-run-1",
      projectPath: "/tmp/App",
      udid: "UDID-1"
    ))

    let monitor = SimulatorRunRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { _ in
      throw SimulatorRunRequestHandlingError.invalidTarget
    }

    await waitForSimulatorMonitorCondition {
      let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
      return ((try? queue.pendingRequests().isEmpty) == true)
        && FileManager.default.fileExists(atPath: failedURL.path)
    }
    await monitor.stop()
  }
}

private actor SimulatorRunRequestRecorder {
  private var recordedRequests: [SimulatorRunRequest] = []

  func record(_ request: SimulatorRunRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [SimulatorRunRequest] {
    recordedRequests
  }
}

private func waitForSimulatorMonitorCondition(
  timeout: Duration = .seconds(2),
  condition: @escaping () async -> Bool
) async {
  let start = ContinuousClock.now
  while !(await condition()), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(await condition())
}

private func temporarySimulatorMonitorRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-simulator-monitor-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
