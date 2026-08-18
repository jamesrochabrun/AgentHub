import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionJSONLParser artifact detection")
struct SessionJSONLParserArtifactTests {
  private let artifactID = "1502bf42-f488-49b5-a995-0402ef54bf6b"

  private func toolUseLine(title: String, filePath: String) -> String {
    """
    {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Artifact","input":{"file_path":"\(filePath)","title":"\(title)"}}]}}
    """
  }

  private func toolResultLine() -> String {
    """
    {"type":"user","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":[{"tool_use_id":"tu1","type":"tool_result","content":"Published /tmp/hero.html at https://claude.ai/code/artifact/\(artifactID)"}]}}
    """
  }

  private func frameLinkLine() -> String {
    """
    {"type":"frame-link","sessionId":"s1","path":"/tmp/hero.html","frameUrl":"https://claude.ai/code/artifact/\(artifactID)","title":"Hero Directions","timestamp":"2026-01-01T00:00:01Z"}
    """
  }

  @Test("An Artifact publish is filed with the title the agent published it under")
  func filesPublishWithTitle() throws {
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(
      [toolUseLine(title: "Hero Directions", filePath: "/tmp/hero.html"), toolResultLine()],
      into: &result
    )

    #expect(result.detectedArtifacts.count == 1)
    let artifact = try #require(result.detectedArtifacts.first)
    #expect(artifact.id == artifactID)
    #expect(artifact.url.absoluteString == "https://claude.ai/code/artifact/\(artifactID)")
    #expect(artifact.title == "Hero Directions")
    #expect(artifact.filePath == "/tmp/hero.html")
    #expect(artifact.revision == 1)
    #expect(result.pendingArtifactPublishes.isEmpty)
  }

  @Test("A frame-link entry files the artifact on its own")
  func filesFrameLinkArtifact() throws {
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([frameLinkLine()], into: &result)

    let artifact = try #require(result.detectedArtifacts.first)
    #expect(artifact.title == "Hero Directions")
    #expect(artifact.filePath == "/tmp/hero.html")
    #expect(artifact.revision == 1)
  }

  @Test("Republishing the same artifact bumps its revision instead of duplicating it")
  func republishBumpsRevision() throws {
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(
      [toolUseLine(title: "Hero Directions", filePath: "/tmp/hero.html"), toolResultLine()],
      into: &result
    )
    let firstRevision = result.detectedArtifacts.first?.revision ?? 0

    SessionJSONLParser.parseNewLines(
      [toolUseLine(title: "Hero Directions v2", filePath: "/tmp/hero.html"), toolResultLine()],
      into: &result
    )

    #expect(result.detectedArtifacts.count == 1)
    let artifact = try #require(result.detectedArtifacts.first)
    #expect(artifact.revision == firstRevision + 1)
    #expect(artifact.title == "Hero Directions v2")
  }

  @Test("A bare mention in assistant text is filed, but not as a publish")
  func filesBareMentionWithoutPublish() throws {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Two hero directions: https://claude.ai/code/artifact/\(artifactID)"}]}}
      """

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    let artifact = try #require(result.detectedArtifacts.first)
    #expect(artifact.id == artifactID)
    #expect(artifact.revision == 0)
    #expect(artifact.title == nil)
  }

  @Test("A mention after a publish keeps the published title and revision")
  func mentionDoesNotClobberPublishMetadata() throws {
    let mention = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Here it is: https://claude.ai/code/artifact/\(artifactID)"}]}}
      """

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(
      [toolUseLine(title: "Hero Directions", filePath: "/tmp/hero.html"), toolResultLine(), mention],
      into: &result
    )

    #expect(result.detectedArtifacts.count == 1)
    let artifact = try #require(result.detectedArtifacts.first)
    #expect(artifact.title == "Hero Directions")
    #expect(artifact.revision == 1)
  }

  @Test("An entry whose title/path aren't strings still parses")
  func lenientFrameLinkFieldDecoding() {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","path":{"nested":true},"title":42,"message":{"role":"assistant","content":[{"type":"text","text":"hello"}],"usage":{"output_tokens":7}}}
      """

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.messageCount == 1)
    #expect(result.totalOutputTokens == 7)
    #expect(result.detectedArtifacts.isEmpty)
  }

  @Test("Sessions without artifacts stay empty")
  func noArtifactsWithoutSignal() {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Preview is ready at http://localhost:3000"}]}}
      """

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedArtifacts.isEmpty)
  }
}
