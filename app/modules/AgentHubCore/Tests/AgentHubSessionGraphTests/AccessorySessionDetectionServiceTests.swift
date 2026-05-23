import Foundation
import Testing

@testable import AgentHubSessionGraph

@Suite("Accessory session detection service")
struct AccessorySessionDetectionServiceTests {
  @Test("Claude detection ignores baseline files and finds new cwd session")
  func detectsNewClaudeSession() throws {
    let root = try temporaryAccessoryDetectionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectPath = root.appending(path: "project").path
    try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    let claudePath = root.appending(path: ".claude").path
    let projectDir = root
      .appending(path: ".claude/projects/\(projectPath.claudeProjectPathEncoded)")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    try "{}\n".write(to: projectDir.appending(path: "existing.jsonl"), atomically: true, encoding: .utf8)

    let service = AccessorySessionDetectionService(
      claudeDataPath: claudePath,
      codexDataPath: root.appending(path: ".codex").path
    )
    let startedAt = Date()
    let baseline = service.makeBaseline(provider: .claude, projectPath: projectPath, startedAt: startedAt)

    try "{}\n".write(to: projectDir.appending(path: "child-session.jsonl"), atomically: true, encoding: .utf8)

    let result = service.detectNewSession(
      provider: .claude,
      projectPath: projectPath,
      startedAt: startedAt,
      baseline: baseline
    )

    #expect(result?.provider == .claude)
    #expect(result?.sessionId == "child-session")
    #expect(result?.projectPath == projectPath)
  }

  @Test("Claude detection ignores modified baseline files")
  func ignoresModifiedBaselineClaudeSession() throws {
    let root = try temporaryAccessoryDetectionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectPath = root.appending(path: "project").path
    try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    let claudePath = root.appending(path: ".claude").path
    let projectDir = root
      .appending(path: ".claude/projects/\(projectPath.claudeProjectPathEncoded)")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let existingFile = projectDir.appending(path: "existing.jsonl")
    try "{}\n".write(to: existingFile, atomically: true, encoding: .utf8)

    let service = AccessorySessionDetectionService(
      claudeDataPath: claudePath,
      codexDataPath: root.appending(path: ".codex").path
    )
    let startedAt = Date()
    let baseline = service.makeBaseline(provider: .claude, projectPath: projectPath, startedAt: startedAt)

    try "{\"updated\":true}\n".write(to: existingFile, atomically: true, encoding: .utf8)

    let result = service.detectNewSession(
      provider: .claude,
      projectPath: projectPath,
      startedAt: startedAt,
      baseline: baseline
    )

    #expect(result == nil)
  }

  @Test("Claude detection rejects ambiguous new sessions")
  func rejectsAmbiguousClaudeSessions() throws {
    let root = try temporaryAccessoryDetectionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let projectPath = root.appending(path: "project").path
    try FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)
    let claudePath = root.appending(path: ".claude").path
    let projectDir = root
      .appending(path: ".claude/projects/\(projectPath.claudeProjectPathEncoded)")
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

    let service = AccessorySessionDetectionService(
      claudeDataPath: claudePath,
      codexDataPath: root.appending(path: ".codex").path
    )
    let startedAt = Date()
    let baseline = service.makeBaseline(provider: .claude, projectPath: projectPath, startedAt: startedAt)

    try "{}\n".write(to: projectDir.appending(path: "first.jsonl"), atomically: true, encoding: .utf8)
    try "{}\n".write(to: projectDir.appending(path: "second.jsonl"), atomically: true, encoding: .utf8)

    let result = service.detectNewSession(
      provider: .claude,
      projectPath: projectPath,
      startedAt: startedAt,
      baseline: baseline
    )

    #expect(result == nil)
  }

  @Test("Codex detection requires matching cwd")
  func codexDetectionRequiresMatchingCWD() throws {
    let root = try temporaryAccessoryDetectionDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let codexPath = root.appending(path: ".codex").path
    let sessionsDir = root.appending(path: ".codex/sessions/2026/05/22")
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let service = AccessorySessionDetectionService(
      claudeDataPath: root.appending(path: ".claude").path,
      codexDataPath: codexPath
    )
    let projectPath = "/tmp/accessory-project"
    let startedAt = Date()
    let baseline = service.makeBaseline(provider: .codex, projectPath: projectPath, startedAt: startedAt)

    try codexSessionFile(sessionId: "wrong", cwd: "/tmp/other")
      .write(to: sessionsDir.appending(path: "wrong.jsonl"), atomically: true, encoding: .utf8)
    try codexSessionFile(sessionId: "right", cwd: projectPath)
      .write(to: sessionsDir.appending(path: "right.jsonl"), atomically: true, encoding: .utf8)

    let result = service.detectNewSession(
      provider: .codex,
      projectPath: projectPath,
      startedAt: startedAt,
      baseline: baseline
    )

    #expect(result?.provider == .codex)
    #expect(result?.sessionId == "right")
    #expect(result?.projectPath == projectPath)
  }
}

private func codexSessionFile(sessionId: String, cwd: String) -> String {
  let meta: [String: Any] = [
    "timestamp": "2026-05-22T12:00:00.000Z",
    "type": "session_meta",
    "payload": [
      "id": sessionId,
      "timestamp": "2026-05-22T12:00:00.000Z",
      "cwd": cwd,
      "git": ["branch": "main"]
    ]
  ]
  let data = try! JSONSerialization.data(withJSONObject: meta)
  return String(decoding: data, as: UTF8.self) + "\n"
}

private func temporaryAccessoryDetectionDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "accessory_detection_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
