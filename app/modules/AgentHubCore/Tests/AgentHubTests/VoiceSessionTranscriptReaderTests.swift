import Foundation
import Testing
@testable import AgentHubCore

struct VoiceSessionTranscriptReaderTests {
  @Test
  func claudeReturnsTrailingAssistantTextAfterLastToolResult() {
    let jsonl = lines(
      claudeUser("run the tests"),
      claudeAssistant(text: "Starting the test run."),
      claudeAssistant(toolUse: "Bash"),
      claudeToolResult("exit 0"),
      claudeAssistant(text: "All 23 tests passed."),
      claudeAssistant(text: "No further action needed.")
    )

    let text = VoiceSessionTranscriptReader.extractLatestAssistantText(
      fromJSONL: jsonl,
      provider: .claude
    )

    #expect(text == "All 23 tests passed.\n\nNo further action needed.")
  }

  @Test
  func claudeSkipsThinkingAndToolOnlyLines() {
    let jsonl = lines(
      claudeUser("hello"),
      claudeAssistant(thinking: "pondering"),
      claudeAssistant(text: "Here is the answer."),
      claudeAssistant(toolUse: "Read")
    )

    let text = VoiceSessionTranscriptReader.extractLatestAssistantText(
      fromJSONL: jsonl,
      provider: .claude
    )

    #expect(text == "Here is the answer.")
  }

  @Test
  func claudeFindsResponseFromEarlierTurnWhenUserSpokeLast() {
    let jsonl = lines(
      claudeUser("first question"),
      claudeAssistant(text: "First answer."),
      claudeUser("second question, still unanswered")
    )

    let text = VoiceSessionTranscriptReader.extractLatestAssistantText(
      fromJSONL: jsonl,
      provider: .claude
    )

    #expect(text == "First answer.")
  }

  @Test
  func claudeReturnsNilWithoutAssistantText() {
    let jsonl = lines(
      claudeUser("hello"),
      claudeAssistant(toolUse: "Bash"),
      claudeToolResult("output")
    )

    let text = VoiceSessionTranscriptReader.extractLatestAssistantText(
      fromJSONL: jsonl,
      provider: .claude
    )

    #expect(text == nil)
  }

  @Test
  func claudeTruncatesVeryLongResponses() {
    let long = String(repeating: "a", count: 6_000)
    let jsonl = lines(claudeAssistant(text: long))

    let text = VoiceSessionTranscriptReader.extractLatestAssistantText(
      fromJSONL: jsonl,
      provider: .claude
    )

    #expect(text?.count == VoiceSessionTranscriptReader.maximumCharacters + 1)
    #expect(text?.hasSuffix("…") == true)
  }

  @Test
  func codexReturnsLatestAgentMessage() {
    let jsonl = lines(
      codexEvent(type: "user_message", message: "run the tests"),
      codexEvent(type: "agent_message", message: "Older answer."),
      codexEvent(type: "agent_reasoning", message: "thinking"),
      codexEvent(type: "agent_message", message: "Tests passed."),
      codexEvent(type: "token_count", message: nil)
    )

    let text = VoiceSessionTranscriptReader.extractLatestAssistantText(
      fromJSONL: jsonl,
      provider: .codex
    )

    #expect(text == "Tests passed.")
  }

  @Test
  func codexReturnsNilWithoutAgentMessages() {
    let jsonl = lines(
      codexEvent(type: "user_message", message: "hello")
    )

    let text = VoiceSessionTranscriptReader.extractLatestAssistantText(
      fromJSONL: jsonl,
      provider: .codex
    )

    #expect(text == nil)
  }

  @Test
  func readsFromFileOnDisk() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("voice-transcript-\(UUID().uuidString).jsonl")
      .path
    defer { try? FileManager.default.removeItem(atPath: path) }
    try lines(claudeAssistant(text: "From disk.")).write(
      toFile: path,
      atomically: true,
      encoding: .utf8
    )

    let reader = VoiceSessionTranscriptReader()
    let text = await reader.latestAssistantText(atPath: path, provider: .claude)
    #expect(text == "From disk.")

    let missing = await reader.latestAssistantText(
      atPath: path + ".missing",
      provider: .claude
    )
    #expect(missing == nil)
  }

  // MARK: - Fixtures

  private func lines(_ entries: String...) -> String {
    entries.joined(separator: "\n")
  }

  private func claudeAssistant(text: String) -> String {
    claudeLine(
      type: "assistant",
      content: [["type": "text", "text": text]]
    )
  }

  private func claudeAssistant(thinking: String) -> String {
    claudeLine(
      type: "assistant",
      content: [["type": "thinking", "thinking": thinking]]
    )
  }

  private func claudeAssistant(toolUse name: String) -> String {
    claudeLine(
      type: "assistant",
      content: [["type": "tool_use", "id": "tool-1", "name": name]]
    )
  }

  private func claudeUser(_ text: String) -> String {
    claudeLine(type: "user", content: [["type": "text", "text": text]])
  }

  private func claudeToolResult(_ text: String) -> String {
    claudeLine(
      type: "user",
      content: [
        ["type": "tool_result", "tool_use_id": "tool-1", "content": text],
      ]
    )
  }

  private func claudeLine(
    type: String,
    content: [[String: Any]]
  ) -> String {
    encode([
      "type": type,
      "message": ["role": type, "content": content],
    ])
  }

  private func codexEvent(type: String, message: String?) -> String {
    var payload: [String: Any] = ["type": type]
    if let message {
      payload["message"] = message
    }
    return encode(["type": "event_msg", "payload": payload])
  }

  private func encode(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
  }
}
