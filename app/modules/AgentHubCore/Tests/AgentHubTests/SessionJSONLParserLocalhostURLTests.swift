import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionJSONLParser localhost URL extraction")
struct SessionJSONLParserLocalhostURLTests {

  @Test("Normalizes wildcard-only localhost URLs from assistant text")
  func normalizesWildcardOnlyLocalhostURLs() {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Preview is ready at http://localhost:3000/**."}]}}
      """

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedLocalhostURL?.absoluteString == "http://localhost:3000")
  }

  @Test("Preserves meaningful localhost routes and query strings")
  func preservesMeaningfulLocalhostRoutesAndQueries() {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Open http://localhost:3000/dashboard?tab=1"}]}}
      """

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedLocalhostURL?.absoluteString == "http://localhost:3000/dashboard?tab=1")
  }

  @Test("Keeps clean tool result localhost URL when assistant repeats wildcard version")
  func keepsCleanToolResultURLWhenAssistantRepeatsWildcardVersion() {
    let toolResultLine = """
      {"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Server ready at http://localhost:3000"}]}}
      """
    let assistantLine = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"Use http://localhost:3000/**."}]}}
      """

    var result = SessionJSONLParser.ParseResult()
    result.pendingToolUses["tu1"] = .init(
      toolName: "Bash",
      toolUseId: "tu1",
      timestamp: Date(),
      input: nil,
      codeChangeInput: nil
    )

    SessionJSONLParser.parseNewLines([toolResultLine, assistantLine], into: &result)

    #expect(result.detectedLocalhostURL?.absoluteString == "http://localhost:3000")
  }
}
