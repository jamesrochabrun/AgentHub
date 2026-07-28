import Foundation
import Testing

@testable import AgentHubCore

@Suite("PendingSessionDirectoryWatcher", .serialized)
struct PendingSessionDirectoryWatcherTests {

  @Test("Resolves when a new .jsonl file appears")
  func resolvesWhenNewJSONLAppears() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = PendingSessionDirectoryWatcher()
    async let outcome = watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])

    try await Task.sleep(for: .milliseconds(100))
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("session-a.jsonl").path,
      contents: Data("{}".utf8)
    )

    #expect(await outcome == .found("session-a.jsonl"))
  }

  @Test("Ignores excluded pre-existing files and non-jsonl files")
  func ignoresExcludedAndNonJSONLFiles() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("existing.jsonl").path,
      contents: Data()
    )

    let watcher = PendingSessionDirectoryWatcher()
    async let outcome = watcher.waitForNewJSONLFile(
      inDirectory: directory.path,
      excluding: ["existing.jsonl"]
    )

    try await Task.sleep(for: .milliseconds(100))
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("notes.txt").path,
      contents: Data()
    )
    try await Task.sleep(for: .milliseconds(100))
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("session-b.jsonl").path,
      contents: Data()
    )

    #expect(await outcome == .found("session-b.jsonl"))
  }

  @Test("Resolves a file that appeared before the watch armed")
  func resolvesFileCreatedBeforeArming() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Simulates the race where the session file lands between the caller's
    // directory snapshot and the kqueue source arming: no further directory
    // writes will occur, so only the initial check can catch it.
    FileManager.default.createFile(
      atPath: directory.appendingPathComponent("early.jsonl").path,
      contents: Data()
    )

    let watcher = PendingSessionDirectoryWatcher()
    let outcome = await watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])
    #expect(outcome == .found("early.jsonl"))
  }

  @Test("cancel() resolves the wait as cancelled")
  func cancelResolvesWait() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = PendingSessionDirectoryWatcher()
    async let outcome = watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])
    try await Task.sleep(for: .milliseconds(100))
    watcher.cancel()

    #expect(await outcome == .cancelled)
  }

  @Test("cancel() before the wait starts resolves immediately")
  func cancelBeforeStart() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = PendingSessionDirectoryWatcher()
    watcher.cancel()
    let outcome = await watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])
    #expect(outcome == .cancelled)
  }

  @Test("Unwatchable directory reports unableToWatch")
  func unwatchableDirectory() async {
    let watcher = PendingSessionDirectoryWatcher()
    let outcome = await watcher.waitForNewJSONLFile(
      inDirectory: "/nonexistent/agenthub-test-\(UUID().uuidString)",
      excluding: []
    )
    #expect(outcome == .unableToWatch)
  }

  /// Regression guard for the original leak: cancelled/abandoned watches must
  /// release their directory descriptor. Runs many cycles and asserts the
  /// process open-fd count does not grow with them.
  @Test("Cancelled watches release their directory descriptors")
  func cancelReleasesDirectoryDescriptors() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let baseline = openFileDescriptorCount()
    for cycle in 0..<20 {
      let watcher = PendingSessionDirectoryWatcher()
      async let outcome = watcher.waitForNewJSONLFile(inDirectory: directory.path, excluding: [])
      if cycle.isMultiple(of: 2) {
        try await Task.sleep(for: .milliseconds(20))
      }
      watcher.cancel()
      _ = await outcome
    }

    // Other suites run in the same process and open fds transiently; sample a
    // few times and take the minimum so only a real (persistent) leak fails.
    var after = Int.max
    for _ in 0..<5 {
      after = min(after, openFileDescriptorCount())
      try await Task.sleep(for: .milliseconds(50))
    }

    #expect(baseline > 0)
    #expect(after <= baseline + 5)
  }

  // MARK: - Helpers

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PendingSessionDirectoryWatcherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func openFileDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
  }
}
