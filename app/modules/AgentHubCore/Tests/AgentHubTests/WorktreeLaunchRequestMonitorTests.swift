import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@Suite("WorktreeLaunchRequestMonitor")
struct WorktreeLaunchRequestMonitorTests {
  @Test("Monitor handles queued request and removes it")
  func monitorHandlesQueuedRequestAndRemovesIt() async throws {
    let directory = try temporaryMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeLaunchRequestQueue(directoryURL: directory)
    let request = WorktreeLaunchRequest(
      id: "request-1",
      provider: .claude,
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      prompt: "Implement feature"
    )
    try queue.enqueue(request)

    let recorder = WorktreeLaunchRequestRecorder()
    let monitor = WorktreeLaunchRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { queued in
      await recorder.record(queued.request)
    }

    await waitForMonitorCondition {
      await recorder.requests() == [request]
        && ((try? queue.pendingRequests().isEmpty) == true)
    }
    await monitor.stop()
  }

  @Test("Monitor marks failed request out of pending queue")
  func monitorMarksFailedRequestOutOfPendingQueue() async throws {
    let directory = try temporaryMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeLaunchRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(WorktreeLaunchRequest(
      id: "request-1",
      provider: .codex,
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      prompt: "Implement feature"
    ))

    let monitor = WorktreeLaunchRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { _ in
      throw WorktreeLaunchRequestHandlingError.emptyPrompt
    }

    await waitForMonitorCondition {
      let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
      return ((try? queue.pendingRequests().isEmpty) == true)
        && FileManager.default.fileExists(atPath: failedURL.path)
    }
    await monitor.stop()
  }
}

private actor WorktreeLaunchRequestRecorder {
  private var recordedRequests: [WorktreeLaunchRequest] = []

  func record(_ request: WorktreeLaunchRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [WorktreeLaunchRequest] {
    recordedRequests
  }
}

private func waitForMonitorCondition(
  timeout: Duration = .seconds(2),
  condition: @escaping () async -> Bool
) async {
  let start = ContinuousClock.now
  while !(await condition()), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(await condition())
}

private func temporaryMonitorRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-launch-monitor-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
