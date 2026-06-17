import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("SimulatorRunRequestQueue")
struct SimulatorRunRequestQueueTests {
  @Test("Enqueue writes pending simulator run request")
  func enqueueWritesPendingRequest() throws {
    let directory = try temporarySimulatorRunRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SimulatorRunRequestQueue(directoryURL: directory)
    let request = SimulatorRunRequest(
      id: "request-1",
      createdAt: Date(timeIntervalSince1970: 1_000),
      projectPath: "/tmp/App",
      udid: "UDID-1",
      sourceProvider: .codex,
      sourceSessionId: "session-1",
      reason: "verify latest changes"
    )

    let queued = try queue.enqueue(request)
    let pending = try queue.pendingRequests()

    #expect(FileManager.default.fileExists(atPath: queued.fileURL.path))
    #expect(pending.map(\.request) == [request])
  }

  @Test("Remove deletes handled simulator run request")
  func removeDeletesHandledRequest() throws {
    let directory = try temporarySimulatorRunRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SimulatorRunRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(SimulatorRunRequest(
      id: "request-1",
      projectPath: "/tmp/App",
      udid: "UDID-1"
    ))

    try queue.remove(queued)

    #expect(try queue.pendingRequests().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: queued.fileURL.path))
  }

  @Test("Mark failed moves simulator request out of pending queue")
  func markFailedMovesRequestOutOfPendingQueue() throws {
    let directory = try temporarySimulatorRunRequestDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = SimulatorRunRequestQueue(directoryURL: directory)
    let queued = try queue.enqueue(SimulatorRunRequest(
      id: "request-1",
      projectPath: "/tmp/App",
      udid: "UDID-1"
    ))

    try queue.markFailed(queued)

    let failedURL = queued.fileURL.deletingPathExtension().appendingPathExtension("failed")
    #expect(try queue.pendingRequests().isEmpty)
    #expect(FileManager.default.fileExists(atPath: failedURL.path))
  }
}

private func temporarySimulatorRunRequestDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-simulator-run-request-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("requests", isDirectory: true)
}
