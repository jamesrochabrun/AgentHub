import Foundation
import Testing

@testable import AgentHubSessionGraph

@Suite("CodexSessionFileScanner")
struct CodexSessionFileScannerTests {
  @Test("Reads session metadata when the first JSONL line exceeds sixteen kilobytes")
  func readsOversizedSessionMetaLine() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = "55555555-5555-5555-5555-555555555555"
    let projectPath = "/tmp/oversized-project"
    let sessionFile = root.appending(path: "session.jsonl")

    try oversizedCodexSessionFileContents(
      sessionID: sessionID,
      cwd: projectPath,
      branch: "feature/oversized-meta",
      baseInstructionsLength: 24_000
    )
    .write(to: sessionFile, atomically: true, encoding: .utf8)

    let meta = try #require(CodexSessionFileScanner.readSessionMeta(from: sessionFile.path))

    #expect(meta.sessionId == sessionID)
    #expect(meta.projectPath == projectPath)
    #expect(meta.branch == "feature/oversized-meta")
    #expect(meta.sessionFilePath == sessionFile.path)

    let expectedDate = ISO8601DateFormatter().date(from: "2026-05-05T12:00:00.000Z")
    #expect(meta.startedAt == expectedDate)
  }
}

private func oversizedCodexSessionFileContents(
  sessionID: String,
  cwd: String,
  branch: String,
  baseInstructionsLength: Int
) -> String {
  let sessionMeta: [String: Any] = [
    "timestamp": "2026-05-05T12:00:00.000Z",
    "type": "session_meta",
    "payload": [
      "id": sessionID,
      "timestamp": "2026-05-05T12:00:00.000Z",
      "cwd": cwd,
      "git": [
        "branch": branch
      ],
      "base_instructions": [
        "text": String(repeating: "x", count: baseInstructionsLength)
      ]
    ]
  ]
  let userMessage: [String: Any] = [
    "timestamp": "2026-05-05T12:00:01.000Z",
    "type": "event_msg",
    "payload": [
      "type": "user_message",
      "message": "hello"
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

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "codex_session_file_scanner_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
