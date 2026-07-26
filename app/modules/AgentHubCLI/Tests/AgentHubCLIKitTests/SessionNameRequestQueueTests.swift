import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("SessionNameRequestQueue")
struct SessionNameRequestQueueTests {
  @Test("Enqueue writes pending session name request and preserves payload")
  func enqueueWritesPendingRequest() throws {
    let directory = try temporarySessionNameRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SessionNameRequestQueue(directoryURL: directory)
    let request = SessionNameRequest(
      id: "name-1",
      createdAt: Date(timeIntervalSince1970: 3_000),
      name: "Focused Session Naming",
      sourceProvider: .codex,
      sourceSessionId: "session-1",
      sourceProcessId: 42
    )

    let queued = try queue.enqueue(request)
    let pending = try queue.pendingRequests()

    #expect(FileManager.default.fileExists(atPath: queued.fileURL.path))
    #expect(pending.map(\.request) == [request])
  }

  @Test("Remove deletes handled session name request")
  func removeDeletesHandledRequest() throws {
    let directory = try temporarySessionNameRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SessionNameRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(SessionNameRequest(
      id: "name-1",
      name: "Session Name",
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 84
    ))

    try queue.remove(queued)

    #expect(try queue.pendingRequests().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: queued.fileURL.path))
  }

  @Test("Mark failed moves request out of pending queue")
  func markFailedMovesRequestOutOfPendingQueue() throws {
    let directory = try temporarySessionNameRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SessionNameRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(SessionNameRequest(
      id: "name-1",
      name: "Session Name",
      sourceProvider: .claude,
      sourceSessionId: nil,
      sourceProcessId: 84
    ))

    try queue.markFailed(queued)

    let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
    #expect(try queue.pendingRequests().isEmpty)
    #expect(FileManager.default.fileExists(atPath: failedURL.path))
  }
}

private func temporarySessionNameRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-session-name-request-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
