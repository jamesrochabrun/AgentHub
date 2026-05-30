import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("WorktreeProgressQueue")
struct WorktreeProgressQueueTests {

  @Test("Write then read round-trips the snapshot")
  func writeReadRoundTrip() throws {
    let directory = try temporaryProgressDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeProgressQueue(directoryURL: directory)
    let snapshot = WorktreeProgressSnapshot(
      operationID: "op-1",
      branchName: "feature/x",
      repositoryPath: "/tmp/repo",
      provider: .claude,
      progress: .updatingFiles(current: 84, total: 194),
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    try queue.write(snapshot)
    let pending = try queue.pendingSnapshots()

    #expect(pending == [snapshot])
    #expect(FileManager.default.fileExists(atPath: queue.fileURL(for: "op-1").path))
  }

  @Test("Write overwrites the previous snapshot for the same operation")
  func writeOverwrites() throws {
    let directory = try temporaryProgressDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeProgressQueue(directoryURL: directory)
    try queue.write(snapshot(id: "op-1", progress: .preparing(message: "Preparing…"), at: 1))
    try queue.write(snapshot(id: "op-1", progress: .completed(path: "/tmp/repo/.worktrees/x"), at: 2))

    let pending = try queue.pendingSnapshots()
    #expect(pending.count == 1)
    #expect(pending.first?.progress == .completed(path: "/tmp/repo/.worktrees/x"))
  }

  @Test("Remove deletes a single operation's file")
  func removeDeletes() throws {
    let directory = try temporaryProgressDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeProgressQueue(directoryURL: directory)
    try queue.write(snapshot(id: "op-1", progress: .preparing(message: "x"), at: 1))
    try queue.write(snapshot(id: "op-2", progress: .preparing(message: "y"), at: 1))

    try queue.remove(operationID: "op-1")

    let pending = try queue.pendingSnapshots()
    #expect(pending.map(\.operationID) == ["op-2"])
  }

  @Test("wipeAll clears every snapshot file")
  func wipeAllClears() throws {
    let directory = try temporaryProgressDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let queue = WorktreeProgressQueue(directoryURL: directory)
    try queue.write(snapshot(id: "op-1", progress: .preparing(message: "x"), at: 1))
    try queue.write(snapshot(id: "op-2", progress: .preparing(message: "y"), at: 2))

    try queue.wipeAll()

    #expect(try queue.pendingSnapshots().isEmpty)
  }

  @Test("WorktreeCreationProgress round-trips through Codable for every case")
  func progressCodableRoundTrip() throws {
    let cases: [WorktreeCreationProgress] = [
      .idle,
      .preparing(message: "Preparing worktree…"),
      .updatingFiles(current: 84, total: 194),
      .completed(path: "/tmp/repo/.worktrees/feature"),
      .cancelled(message: "Cancelled by user"),
      .failed(error: "Directory already exists")
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for value in cases {
      let data = try encoder.encode(value)
      let decoded = try decoder.decode(WorktreeCreationProgress.self, from: data)
      #expect(decoded == value)
    }
  }

  // MARK: - Helpers

  private func snapshot(
    id: String,
    progress: WorktreeCreationProgress,
    at seconds: TimeInterval
  ) -> WorktreeProgressSnapshot {
    WorktreeProgressSnapshot(
      operationID: id,
      branchName: "feature/\(id)",
      repositoryPath: "/tmp/repo",
      provider: .claude,
      progress: progress,
      updatedAt: Date(timeIntervalSince1970: seconds)
    )
  }
}

private func temporaryProgressDirectory() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-progress-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.appendingPathComponent("worktree-progress", isDirectory: true)
}
