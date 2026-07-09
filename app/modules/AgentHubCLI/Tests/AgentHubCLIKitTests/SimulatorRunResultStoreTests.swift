import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("SimulatorRunResultStore")
struct SimulatorRunResultStoreTests {
  @Test("Write round-trips a run result by request id")
  func writeRoundTripsResult() throws {
    let directory = try temporaryResultDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = SimulatorRunResultStore(directoryURL: directory)
    let result = SimulatorRunResult(
      requestId: "request-1",
      status: .failed,
      projectPath: "/tmp/App",
      udid: "UDID-1",
      errorMessage: "Build failed: use of unresolved identifier 'foo'",
      hotReloadArmed: false,
      finishedAt: Date(timeIntervalSince1970: 1_000)
    )

    try store.write(result)

    #expect(store.result(requestId: "request-1") == result)
    #expect(store.result(requestId: "missing") == nil)
  }

  @Test("waitForResult returns an already-written result immediately")
  func waitForResultReturnsExistingResult() async throws {
    let directory = try temporaryResultDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = SimulatorRunResultStore(directoryURL: directory)
    let result = SimulatorRunResult(
      requestId: "request-1",
      status: .succeeded,
      projectPath: "/tmp/App",
      udid: "UDID-1",
      hotReloadArmed: true,
      // Whole seconds: iso8601 round-trips drop fractional seconds.
      finishedAt: Date(timeIntervalSince1970: 2_000)
    )
    try store.write(result)

    let awaited = await store.waitForResult(
      requestId: "request-1",
      timeout: .seconds(5),
      pollInterval: .milliseconds(10)
    )
    #expect(awaited == result)
  }

  @Test("waitForResult picks up a result written mid-wait")
  func waitForResultPicksUpLateResult() async throws {
    let directory = try temporaryResultDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = SimulatorRunResultStore(directoryURL: directory)
    let result = SimulatorRunResult(
      requestId: "request-1",
      status: .succeeded,
      projectPath: "/tmp/App",
      udid: "UDID-1",
      finishedAt: Date(timeIntervalSince1970: 2_000)
    )

    let writer = Task {
      try? await Task.sleep(for: .milliseconds(50))
      try? store.write(result)
    }
    let awaited = await store.waitForResult(
      requestId: "request-1",
      timeout: .seconds(5),
      pollInterval: .milliseconds(10)
    )
    await writer.value

    #expect(awaited == result)
  }

  @Test("waitForResult times out when no result arrives")
  func waitForResultTimesOut() async throws {
    let directory = try temporaryResultDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = SimulatorRunResultStore(directoryURL: directory)
    let awaited = await store.waitForResult(
      requestId: "request-1",
      timeout: .milliseconds(50),
      pollInterval: .milliseconds(10)
    )
    #expect(awaited == nil)
  }

  @Test("Prune removes only results older than the age limit")
  func pruneRemovesOldResults() throws {
    let directory = try temporaryResultDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let store = SimulatorRunResultStore(directoryURL: directory)
    try store.write(SimulatorRunResult(
      requestId: "old", status: .succeeded, projectPath: "/tmp/App", udid: "UDID-1"
    ))
    try store.write(SimulatorRunResult(
      requestId: "fresh", status: .succeeded, projectPath: "/tmp/App", udid: "UDID-1"
    ))

    let oldURL = store.fileURL(requestId: "old")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7_200)],
      ofItemAtPath: oldURL.path
    )

    store.prune(olderThan: 3_600)

    #expect(store.result(requestId: "old") == nil)
    #expect(store.result(requestId: "fresh") != nil)
  }
}

private func temporaryResultDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-simulator-run-result-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("results", isDirectory: true)
}
