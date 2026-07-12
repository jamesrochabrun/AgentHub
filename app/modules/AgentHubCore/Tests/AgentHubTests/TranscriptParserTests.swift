import Testing

@testable import AgentHubCore

@Suite("Transcript parser extraction")
struct TranscriptParserTests {
  @Test("Claude transcript captures user and assistant text")
  func claudeTranscriptCapturesUserAndAssistantText() {
    let lines = [
      """
      {"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"Please summarize this."}]}}
      """,
      """
      {"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"## Summary\\n\\nDone."}]}}
      """
    ]

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(lines, into: &result)

    #expect(result.transcriptEntries.map(\.role) == [.user, .assistant])
    #expect(result.transcriptEntries.map(\.provider) == [.claude, .claude])
    #expect(result.transcriptEntries.map(\.content) == ["Please summarize this.", "## Summary\n\nDone."])
  }

  @Test("Codex transcript captures user and agent messages")
  func codexTranscriptCapturesUserAndAgentMessages() {
    let lines = [
      """
      {"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"user_message","message":"Write tests."}}
      """,
      """
      {"type":"event_msg","timestamp":"2026-01-01T00:00:01Z","payload":{"type":"agent_message","message":"### Tests\\n\\nAdded."}}
      """
    ]

    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines(lines, into: &result)

    #expect(result.transcriptEntries.map(\.role) == [.user, .assistant])
    #expect(result.transcriptEntries.map(\.provider) == [.codex, .codex])
    #expect(result.transcriptEntries.map(\.content) == ["Write tests.", "### Tests\n\nAdded."])
  }
}
