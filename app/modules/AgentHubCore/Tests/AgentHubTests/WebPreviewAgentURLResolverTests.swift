import Foundation
import Testing

@testable import AgentHubCore

private struct WebPreviewAgentURLResolverFixture {
  let root: URL
  let claudeDataPath: String

  static func create() throws -> WebPreviewAgentURLResolverFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("WebPreviewAgentURLResolverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let claudeRoot = root.appendingPathComponent(".claude/projects", isDirectory: true)
    try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
    return WebPreviewAgentURLResolverFixture(root: root, claudeDataPath: root.appendingPathComponent(".claude").path)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func write(_ path: String, content: String) throws -> String {
    let fileURL = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL.path
  }
}

@Suite("WebPreviewAgentURLResolver")
struct WebPreviewAgentURLResolverTests {

  @Test("Detected monitor-state URL wins over session file fallback")
  func detectedURLWinsOverSessionFileFallback() async throws {
    let fixture = try WebPreviewAgentURLResolverFixture.create()
    defer { fixture.cleanup() }

    let sessionFilePath = try fixture.write(
      "session.jsonl",
      content: #"{"message":{"content":[{"type":"text","text":"Dev server running at http://localhost:8000"}]}}"#
    )
    let session = CLISession(
      id: UUID().uuidString,
      projectPath: "/tmp/project",
      sessionFilePath: sessionFilePath
    )

    let resolvedURL = await WebPreviewAgentURLResolver.resolve(
      for: session,
      detectedLocalhostURL: URL(string: "http://localhost:3000")
    )

    #expect(resolvedURL == URL(string: "http://localhost:3000"))
  }

  @Test("Reads the latest localhost URL from the session file when monitor state is missing")
  func readsLatestLocalhostURLFromSessionFileWhenMonitorStateMissing() async throws {
    let fixture = try WebPreviewAgentURLResolverFixture.create()
    defer { fixture.cleanup() }

    let sessionFilePath = try fixture.write(
      "session.jsonl",
      content: """
      {"message":{"content":[{"type":"text","text":"App ready at http://localhost:5173"}]}}
      {"message":{"content":[{"type":"text","text":"Dev server running at **http://localhost:8000**"}]}}
      """
    )
    let session = CLISession(
      id: UUID().uuidString,
      projectPath: "/tmp/project",
      sessionFilePath: sessionFilePath
    )

    let resolvedURL = await WebPreviewAgentURLResolver.resolve(
      for: session,
      detectedLocalhostURL: nil
    )

    #expect(resolvedURL == URL(string: "http://localhost:8000"))
  }

  @Test("Falls back to the Claude session file path when the model has no explicit sessionFilePath")
  func fallsBackToClaudeSessionFilePathWhenExplicitPathIsMissing() async throws {
    let fixture = try WebPreviewAgentURLResolverFixture.create()
    defer { fixture.cleanup() }

    let projectPath = "/Users/example/site"
    let sessionId = UUID().uuidString
    let encodedPath = projectPath.claudeProjectPathEncoded
    let sessionFilePath = try fixture.write(
      ".claude/projects/\(encodedPath)/\(sessionId).jsonl",
      content: #"{"message":{"content":[{"type":"text","text":"Dev server running at http://127.0.0.1:4173"}]}}"#
    )
    #expect(FileManager.default.fileExists(atPath: sessionFilePath))

    let session = CLISession(
      id: sessionId,
      projectPath: projectPath
    )

    let resolvedURL = await WebPreviewAgentURLResolver.resolve(
      for: session,
      detectedLocalhostURL: nil,
      claudeDataPath: fixture.claudeDataPath
    )

    #expect(resolvedURL == URL(string: "http://127.0.0.1:4173"))
  }
}
