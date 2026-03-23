import Testing

@testable import AgentHubCore

@Suite("CodexSessionJSONLParser localhost URL extraction")
struct CodexSessionJSONLParserLocalhostURLTests {

  @Test("Normalizes wildcard-only localhost URLs from Codex agent messages")
  func normalizesWildcardOnlyLocalhostURLs() {
    let lines = [
      """
      {"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"agent_message","message":"Preview is available at http://localhost:3000/**."}}
      """
    ]

    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines(lines, into: &result)

    #expect(result.detectedLocalhostURL?.absoluteString == "http://localhost:3000")
  }

  @Test("Preserves meaningful localhost routes from Codex tool output")
  func preservesMeaningfulLocalhostRoutes() {
    let lines = [
      """
      {"type":"response_item","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"function_call","name":"shell","call_id":"call-1"}}
      """,
      """
      {"type":"response_item","timestamp":"2026-01-01T00:00:01Z","payload":{"type":"function_call_output","call_id":"call-1","output":"Server ready at http://127.0.0.1:3000/dashboard?tab=1"}}
      """
    ]

    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines(lines, into: &result)

    #expect(result.detectedLocalhostURL?.absoluteString == "http://127.0.0.1:3000/dashboard?tab=1")
  }
}
