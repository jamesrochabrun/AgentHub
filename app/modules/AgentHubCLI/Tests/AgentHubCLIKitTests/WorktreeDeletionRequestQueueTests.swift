import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("WorktreeDeletionRequestQueue")
struct WorktreeDeletionRequestQueueTests {
  @Test("Enqueue writes pending deletion request and preserves payload")
  func enqueueWritesPendingRequest() throws {
    let directory = try temporaryDeletionRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeDeletionRequestQueue(directoryURL: directory)
    let request = WorktreeDeletionRequest(
      id: "delete-1",
      createdAt: Date(timeIntervalSince1970: 2_000),
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      force: true,
      deleteAssociatedBranch: false,
      removeFromDisk: false,
      sourceProvider: .claude,
      sourceSessionId: "source-1"
    )

    let queued = try queue.enqueue(request)
    let pending = try queue.pendingRequests()

    #expect(FileManager.default.fileExists(atPath: queued.fileURL.path))
    #expect(pending.map(\.request) == [request])
  }

  @Test("Remove deletes handled deletion request")
  func removeDeletesHandledRequest() throws {
    let directory = try temporaryDeletionRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeDeletionRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(WorktreeDeletionRequest(
      id: "delete-1",
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature"
    ))

    try queue.remove(queued)

    #expect(try queue.pendingRequests().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: queued.fileURL.path))
  }

  @Test("Mark failed moves deletion request out of pending queue")
  func markFailedMovesRequestOutOfPendingQueue() throws {
    let directory = try temporaryDeletionRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeDeletionRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(WorktreeDeletionRequest(
      id: "delete-1",
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature"
    ))

    try queue.markFailed(queued)

    let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
    #expect(try queue.pendingRequests().isEmpty)
    #expect(FileManager.default.fileExists(atPath: failedURL.path))
  }
}

private func temporaryDeletionRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-cli-deletion-request-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
