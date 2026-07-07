import Foundation
import Testing

@testable import AgentHubCore

@Suite("Worktree disk size")
struct WorktreeDiskSizeTests {
  @Test("Counts hidden files and directories")
  func countsHiddenEntries() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("WorktreeDiskSizeTests-hidden-\(UUID().uuidString)")
    let hiddenDir = base.appendingPathComponent(".build")
    try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    try Data(repeating: 0xEF, count: 8192).write(to: hiddenDir.appendingPathComponent("artifact.o"))
    try Data(repeating: 0x01, count: 4096).write(to: base.appendingPathComponent(".hidden-file"))

    let total = WorktreeDiskSize.bytes(at: base)
    #expect(total >= Int64(8192 + 4096))
  }
}
