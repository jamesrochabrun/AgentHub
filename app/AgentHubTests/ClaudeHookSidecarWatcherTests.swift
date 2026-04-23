import Combine
import Foundation
import Testing
@testable import AgentHubCore

@Suite("ClaudeHookSidecarWatcher")
struct ClaudeHookSidecarWatcherTests {

  private func makeWatcher() -> (ClaudeHookSidecarWatcher, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-sidecar-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let watcher = ClaudeHookSidecarWatcher(approvalsDirectory: dir)
    return (watcher, dir)
  }

  @Test("startWatching picks up pre-existing pending entry")
  func seedsFromExistingFile() async throws {
    let (watcher, dir) = makeWatcher()
    defer { try? FileManager.default.removeItem(at: dir) }

    let sid = "sess-1"
    let file = dir.appendingPathComponent("\(sid).jsonl")
    let line: [String: Any] = [
      "event": "pending",
      "toolName": "Edit",
      "toolUseId": "tu-1",
      "timestamp": "2026-04-23T00:00:00Z",
      "input": [
        "file_path": "/tmp/x.swift",
        "old_string": "a",
        "new_string": "b",
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: line, options: [])
    var jsonl = data
    jsonl.append(0x0A) // newline
    try jsonl.write(to: file)

    await watcher.startWatching(sessionId: sid)

    let info = await watcher.pendingInfo(for: sid)
    #expect(info?.toolName == "Edit")
    #expect(info?.toolUseId == "tu-1")
    #expect(info?.codeChangeInput?.filePath == "/tmp/x.swift")
    #expect(info?.codeChangeInput?.oldString == "a")
    #expect(info?.codeChangeInput?.newString == "b")
  }

  @Test("resolved event clears the pending entry")
  func resolvedClears() async throws {
    let (watcher, dir) = makeWatcher()
    defer { try? FileManager.default.removeItem(at: dir) }

    let sid = "sess-2"
    let file = dir.appendingPathComponent("\(sid).jsonl")

    let pending: [String: Any] = [
      "event": "pending", "toolName": "Bash",
      "toolUseId": "tu-2", "timestamp": "2026-04-23T00:00:00Z",
      "input": ["command": "ls"]
    ]
    let resolved: [String: Any] = [
      "event": "resolved", "toolName": "Bash",
      "toolUseId": "tu-2", "timestamp": "2026-04-23T00:00:01Z",
      "input": [:]
    ]
    var data = Data()
    data.append(try JSONSerialization.data(withJSONObject: pending))
    data.append(0x0A)
    data.append(try JSONSerialization.data(withJSONObject: resolved))
    data.append(0x0A)
    try data.write(to: file)

    await watcher.startWatching(sessionId: sid)

    let info = await watcher.pendingInfo(for: sid)
    #expect(info == nil)
  }

  @Test("publisher emits SidecarUpdate when a new pending line is appended")
  func publishesOnAppend() async throws {
    let (watcher, dir) = makeWatcher()
    defer { try? FileManager.default.removeItem(at: dir) }

    let sid = "sess-3"
    let file = dir.appendingPathComponent("\(sid).jsonl")
    // Create an empty file so the per-file watcher attaches on startWatching.
    FileManager.default.createFile(atPath: file.path, contents: nil)

    await watcher.startWatching(sessionId: sid)

    // Subscribe.
    final class Collector: @unchecked Sendable {
      var updates: [SidecarUpdate] = []
    }
    let collector = Collector()
    let cancellable = watcher.updates.sink { update in
      collector.updates.append(update)
    }
    defer { cancellable.cancel() }

    let line: [String: Any] = [
      "event": "pending", "toolName": "MultiEdit",
      "toolUseId": "tu-3", "timestamp": "2026-04-23T00:00:00Z",
      "input": [
        "file_path": "/tmp/y.swift",
        "edits": [
          ["old_string": "foo", "new_string": "bar"],
        ]
      ]
    ]
    var data = try JSONSerialization.data(withJSONObject: line)
    data.append(0x0A)
    // Append to the file.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.close()

    // Give the DispatchSource a moment to fire.
    try await Task.sleep(for: .milliseconds(300))

    #expect(!collector.updates.isEmpty)
    let update = collector.updates.last
    #expect(update?.sessionId == sid)
    #expect(update?.info?.toolName == "MultiEdit")
  }
}
