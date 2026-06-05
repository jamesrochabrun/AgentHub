import Foundation
import Testing

@testable import AgentHubCore

@Suite("Codex worktree session import")
struct CodexWorktreeSessionImportTests {
  @Test("Loads latest Codex sessions for a worktree import page")
  func loadsLatestCodexWorktreeImportPage() async throws {
    let root = try temporaryDirectory(name: "codex_import")
    defer { try? FileManager.default.removeItem(at: root) }

    let parentPath = root.appending(path: "Project").path
    let worktreePath = root.appending(path: "Project-feature").path
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)

    let service = CodexSessionMonitorService(codexDataPath: root.path)
    await service.registerWorktree(
      WorktreeBranch(name: "feature/import", path: worktreePath, isWorktree: true),
      parentRepositoryPath: parentPath
    )

    try writeCodexSession(root: root, id: "session-1", cwd: worktreePath, timestamp: "2026-05-05T12:01:00.000Z")
    try writeCodexSession(root: root, id: "session-2", cwd: worktreePath + "/app", timestamp: "2026-05-05T12:02:00.000Z")
    try writeCodexSession(root: root, id: "session-3", cwd: worktreePath, timestamp: "2026-05-05T12:03:00.000Z")
    try writeCodexSession(root: root, id: "session-4", cwd: worktreePath, timestamp: "2026-05-05T12:04:00.000Z")
    try writeCodexSession(root: root, id: "session-5", cwd: worktreePath, timestamp: "2026-05-05T12:05:00.000Z")
    try writeCodexSession(root: root, id: "session-out", cwd: root.appending(path: "Other").path, timestamp: "2026-05-05T12:06:00.000Z")

    let page = await service.loadLatestSessions(
      inWorktreePath: worktreePath,
      excludingSessionIds: ["session-5"],
      limit: 3
    )

    #expect(page.sessions.map(\.id) == ["session-4", "session-3", "session-2"])
    #expect(page.sessions.allSatisfy(\.isWorktree))
    #expect(page.hasMore)
  }
}

private func writeCodexSession(
  root: URL,
  id: String,
  cwd: String,
  timestamp: String
) throws {
  let sessionsDirectory = root
    .appending(path: "sessions")
    .appending(path: "2026")
    .appending(path: "05")
    .appending(path: "05")
  try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

  let fileURL = sessionsDirectory.appending(path: "rollout-\(id).jsonl")
  try codexSessionLines(id: id, cwd: cwd, timestamp: timestamp)
    .write(to: fileURL, atomically: true, encoding: .utf8)

  if let modificationDate = iso8601Date(timestamp) {
    try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: fileURL.path)
  }
}

private func codexSessionLines(id: String, cwd: String, timestamp: String) -> String {
  let sessionMeta: [String: Any] = [
    "timestamp": timestamp,
    "type": "session_meta",
    "payload": [
      "id": id,
      "timestamp": timestamp,
      "cwd": cwd,
      "git": [
        "branch": "feature/import"
      ]
    ]
  ]
  let userMessage: [String: Any] = [
    "timestamp": timestamp,
    "type": "event_msg",
    "payload": [
      "type": "user_message",
      "message": id
    ]
  ]

  return """
  \(jsonLine(sessionMeta))
  \(jsonLine(userMessage))

  """
}

private func jsonLine(_ object: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: object)
  return String(decoding: data, as: UTF8.self)
}

private func iso8601Date(_ string: String) -> Date? {
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractionalFormatter.date(from: string) {
    return date
  }

  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: string)
}

private func temporaryDirectory(name: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "\(name)_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
