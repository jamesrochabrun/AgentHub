import AgentHubCLIKit
import Foundation
import Testing

@testable import AgentHubCore

@Suite("WorktreeDeletionRequestMonitor")
struct WorktreeDeletionRequestMonitorTests {
  @Test("Monitor handles queued deletion request and removes it")
  func monitorHandlesQueuedRequestAndRemovesIt() async throws {
    let directory = try temporaryDeletionMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeDeletionRequestQueue(directoryURL: directory)
    let request = WorktreeDeletionRequest(
      id: "delete-1",
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      removeFromDisk: false
    )
    try queue.enqueue(request)

    let recorder = WorktreeDeletionRequestRecorder()
    let monitor = WorktreeDeletionRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { queued in
      await recorder.record(queued.request)
    }

    await waitForDeletionMonitorCondition {
      await recorder.requests() == [request]
        && ((try? queue.pendingRequests().isEmpty) == true)
    }
    await monitor.stop()
  }

  @Test("Monitor marks failed deletion request out of pending queue")
  func monitorMarksFailedRequestOutOfPendingQueue() async throws {
    let directory = try temporaryDeletionMonitorRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeDeletionRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(WorktreeDeletionRequest(
      id: "delete-1",
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature"
    ))

    let monitor = WorktreeDeletionRequestMonitor(queue: queue, pollInterval: .milliseconds(20))
    await monitor.start { _ in
      throw WorktreeDeletionRequestHandlingError.deletionFailed("failed")
    }

    await waitForDeletionMonitorCondition {
      let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
      return ((try? queue.pendingRequests().isEmpty) == true)
        && FileManager.default.fileExists(atPath: failedURL.path)
    }
    await monitor.stop()
  }
}

private actor WorktreeDeletionRequestRecorder {
  private var recordedRequests: [WorktreeDeletionRequest] = []

  func record(_ request: WorktreeDeletionRequest) {
    recordedRequests.append(request)
  }

  func requests() -> [WorktreeDeletionRequest] {
    recordedRequests
  }
}

private func waitForDeletionMonitorCondition(
  timeout: Duration = .seconds(2),
  condition: @escaping () async -> Bool
) async {
  let start = ContinuousClock.now
  while !(await condition()), ContinuousClock.now - start < timeout {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(await condition())
}

private func temporaryDeletionMonitorRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-deletion-monitor-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
