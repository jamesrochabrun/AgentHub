import AgentHubCLIKit
import Combine
import Foundation
import Testing

@testable import AgentHubCore

@Suite("WorktreeProgressSidecarWatcher")
struct WorktreeProgressSidecarWatcherTests {

  @Test("start emits snapshots already on disk")
  func emitsPreexistingOnStart() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let writer = WorktreeProgressQueue(directoryURL: dir)
    try writer.write(snap("op-1", .updatingFiles(current: 1, total: 4)))
    try writer.write(snap("op-2", .preparing(message: "Preparing…")))

    let recorder = SnapshotRecorder()
    let watcher = WorktreeProgressSidecarWatcher(queue: WorktreeProgressQueue(directoryURL: dir))
    let cancellable = watcher.updates.sink { recorder.record($0) }
    defer { cancellable.cancel() }

    // The initial scan runs synchronously inside start().
    await watcher.start()

    #expect(Set(recorder.snapshot().map(\.operationID)) == ["op-1", "op-2"])
  }

  @Test("emits when a snapshot file is written after start")
  func emitsOnLiveWrite() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let writer = WorktreeProgressQueue(directoryURL: dir)

    let recorder = SnapshotRecorder()
    let watcher = WorktreeProgressSidecarWatcher(queue: WorktreeProgressQueue(directoryURL: dir))
    let cancellable = watcher.updates.sink { recorder.record($0) }
    defer { cancellable.cancel() }
    await watcher.start()

    // Atomic temp-then-move write — the directory source must fire and re-scan.
    try writer.write(snap("op-live", .updatingFiles(current: 2, total: 10)))
    try await waitUntil { recorder.snapshot().contains { $0.operationID == "op-live" } }

    #expect(recorder.snapshot().contains { $0.operationID == "op-live" })
  }

  @Test("discardSnapshot removes the file")
  func discardRemovesFile() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try WorktreeProgressQueue(directoryURL: dir).write(snap("op-1", .completed(path: "/tmp/x")))

    let watcher = WorktreeProgressSidecarWatcher(queue: WorktreeProgressQueue(directoryURL: dir))
    await watcher.start()
    await watcher.discardSnapshot(operationID: "op-1")

    #expect(try WorktreeProgressQueue(directoryURL: dir).pendingSnapshots().isEmpty)
  }

  @Test("wipeAll clears the directory")
  func wipeAllClears() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try WorktreeProgressQueue(directoryURL: dir).write(snap("op-1", .preparing(message: "x")))

    let watcher = WorktreeProgressSidecarWatcher(queue: WorktreeProgressQueue(directoryURL: dir))
    await watcher.wipeAll()

    #expect(try WorktreeProgressQueue(directoryURL: dir).pendingSnapshots().isEmpty)
  }

  // MARK: - Helpers

  private func snap(_ id: String, _ progress: WorktreeCreationProgress) -> WorktreeProgressSnapshot {
    WorktreeProgressSnapshot(
      operationID: id,
      branchName: "feature/\(id)",
      repositoryPath: "/tmp/repo",
      provider: .claude,
      progress: progress
    )
  }

  private func tempDir() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-progress-watcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent("worktree-progress", isDirectory: true)
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @escaping () -> Bool
  ) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
}

private final class SnapshotRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [WorktreeProgressSnapshot] = []

  func record(_ snapshot: WorktreeProgressSnapshot) {
    lock.lock()
    items.append(snapshot)
    lock.unlock()
  }

  func snapshot() -> [WorktreeProgressSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}
