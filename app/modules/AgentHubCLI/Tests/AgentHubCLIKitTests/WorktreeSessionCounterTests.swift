import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("WorktreeSessionCounter")
struct WorktreeSessionCounterTests {
  @Test("Counts distinct Claude and Codex sessions by containing worktree")
  func countsSessionsByContainingWorktree() throws {
    let root = try temporaryCounterDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let repoPath = root.appendingPathComponent("repo").path
    let featurePath = root.appendingPathComponent("repo/.worktrees/feature").path
    let otherPath = root.appendingPathComponent("repo/.worktrees/other").path

    let claudePath = root.appendingPathComponent("claude").path
    try FileManager.default.createDirectory(
      atPath: claudePath,
      withIntermediateDirectories: true
    )
    try [
      jsonLine(["sessionId": "claude-main", "project": repoPath]),
      jsonLine(["sessionId": "claude-feature", "project": featurePath]),
      jsonLine(["sessionId": "claude-feature", "project": featurePath + "/subdir"]),
    ].joined(separator: "\n")
      .write(toFile: (claudePath as NSString).appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)

    let codexSessionDir = root.appendingPathComponent("codex/sessions/2026/05/29")
    try FileManager.default.createDirectory(at: codexSessionDir, withIntermediateDirectories: true)
    try codexMetaLine(id: "codex-feature", cwd: featurePath + "/app")
      .write(to: codexSessionDir.appendingPathComponent("session-feature.jsonl"), atomically: true, encoding: .utf8)
    try codexMetaLine(id: "codex-other", cwd: otherPath)
      .write(to: codexSessionDir.appendingPathComponent("session-other.jsonl"), atomically: true, encoding: .utf8)

    let worktrees = [
      WorktreeInfo(path: repoPath, branch: "main", isWorktree: false, mainRepoPath: nil),
      WorktreeInfo(path: featurePath, branch: "feature", isWorktree: true, mainRepoPath: repoPath),
      WorktreeInfo(path: otherPath, branch: "other", isWorktree: true, mainRepoPath: repoPath),
    ]

    let counter = WorktreeSessionCounter(claudeDataPath: claudePath, codexDataPath: root.appendingPathComponent("codex").path)
    let counts = counter.countSessions(for: worktrees)

    #expect(counts[repoPath]?.claude == 1)
    #expect(counts[repoPath]?.codex == 0)
    #expect(counts[featurePath]?.claude == 1)
    #expect(counts[featurePath]?.codex == 1)
    #expect(counts[featurePath]?.total == 2)
    #expect(counts[otherPath]?.claude == 0)
    #expect(counts[otherPath]?.codex == 1)
  }
}

private func codexMetaLine(id: String, cwd: String) -> String {
  jsonLine([
    "type": "session_meta",
    "payload": [
      "id": id,
      "cwd": cwd
    ]
  ]) + "\n"
}

private func jsonLine(_ object: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: object)
  return String(decoding: data, as: UTF8.self)
}

private func temporaryCounterDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("agenthub-counter-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
