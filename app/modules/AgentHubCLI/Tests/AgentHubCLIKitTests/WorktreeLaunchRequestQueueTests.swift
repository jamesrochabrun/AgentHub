import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("WorktreeLaunchRequestQueue")
struct WorktreeLaunchRequestQueueTests {
  @Test("Enqueue writes pending request and preserves payload")
  func enqueueWritesPendingRequest() throws {
    let directory = try temporaryRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeLaunchRequestQueue(directoryURL: directory)
    let request = WorktreeLaunchRequest(
      id: "request-1",
      createdAt: Date(timeIntervalSince1970: 1_000),
      provider: .claude,
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      launchPath: "/tmp/repo/.worktrees/feature/ios/app",
      branchName: "feature",
      prompt: "Implement feature",
      sourceProvider: .codex,
      sourceSessionId: "source-1"
    )

    let queued = try queue.enqueue(request)
    let pending = try queue.pendingRequests()

    #expect(FileManager.default.fileExists(atPath: queued.fileURL.path))
    #expect(pending.map(\.request) == [request])
    #expect(pending.first?.request == request)
  }

  @Test("Pending requests decode legacy payloads without launch path")
  func pendingRequestsDecodeLegacyPayloadsWithoutLaunchPath() throws {
    let directory = try temporaryRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let legacyJSON = """
    {
      "id": "legacy-1",
      "createdAt": 1000,
      "provider": "Claude",
      "repositoryPath": "/tmp/repo",
      "worktreePath": "/tmp/repo/.worktrees/feature",
      "branchName": "feature",
      "prompt": "Implement feature"
    }
    """
    try legacyJSON.write(to: directory.appendingPathComponent("legacy-1.json"), atomically: true, encoding: .utf8)

    let pending = try WorktreeLaunchRequestQueue(directoryURL: directory).pendingRequests()

    let request = try #require(pending.first?.request)
    #expect(request.id == "legacy-1")
    #expect(request.launchPath == nil)
  }

  @Test("Remove deletes handled request")
  func removeDeletesHandledRequest() throws {
    let directory = try temporaryRequestDirectory()
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

    try queue.remove(queued)

    #expect(try queue.pendingRequests().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: queued.fileURL.path))
  }

  @Test("Mark failed moves request out of pending queue")
  func markFailedMovesRequestOutOfPendingQueue() throws {
    let directory = try temporaryRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeLaunchRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(WorktreeLaunchRequest(
      id: "request-1",
      provider: .claude,
      repositoryPath: "/tmp/repo",
      worktreePath: "/tmp/repo/.worktrees/feature",
      branchName: "feature",
      prompt: "Implement feature"
    ))

    try queue.markFailed(queued)

    let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
    #expect(try queue.pendingRequests().isEmpty)
    #expect(FileManager.default.fileExists(atPath: failedURL.path))
  }

  @Test("Provider parses command line and environment style values")
  func providerParsesValues() {
    #expect(WorktreeLaunchProvider(commandLineValue: "claude") == .claude)
    #expect(WorktreeLaunchProvider(commandLineValue: "Claude") == .claude)
    #expect(WorktreeLaunchProvider(commandLineValue: "codex") == .codex)
    #expect(WorktreeLaunchProvider(commandLineValue: "unknown") == nil)
  }
}

private func temporaryRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-cli-request-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
