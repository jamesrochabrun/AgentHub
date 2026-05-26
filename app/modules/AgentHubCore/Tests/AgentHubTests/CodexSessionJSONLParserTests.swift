import Foundation
import Testing

@testable import AgentHubCore

@Suite("CodexSessionJSONLParser")
struct CodexSessionJSONLParserTests {

  @Test("Parses lightweight session summary for targeted Codex restore")
  func parsesSessionSummaryForTargetedRestore() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let sessionFile = directory.appending(path: "session.jsonl")
    let longMessage = String(repeating: "a", count: 600)
    try [
      jsonLine([
        "type": "session_meta",
        "timestamp": "2026-01-01T00:00:00.000Z",
        "payload": [
          "id": "session-1",
          "timestamp": "2026-01-01T00:00:00.000Z",
          "cwd": "/tmp/project"
        ]
      ]),
      jsonLine([
        "type": "event_msg",
        "timestamp": "2026-01-01T00:00:01.000Z",
        "payload": [
          "type": "user_message",
          "message": "  \(longMessage)  "
        ]
      ]),
      jsonLine([
        "type": "event_msg",
        "timestamp": "2026-01-01T00:00:02.000Z",
        "payload": [
          "type": "agent_message",
          "message": "assistant"
        ]
      ]),
      jsonLine([
        "type": "event_msg",
        "timestamp": "2026-01-01T00:00:03.000Z",
        "payload": [
          "type": "user_message",
          "message": "last message"
        ]
      ])
    ].joined(separator: "\n")
      .write(to: sessionFile, atomically: true, encoding: .utf8)

    let result = CodexSessionJSONLParser.parseSessionSummaryFile(at: sessionFile.path)
    let expectedLastActivity = try #require(iso8601Date("2026-01-01T00:00:03.000Z"))

    #expect(result.messageCount == 3)
    #expect(result.firstUserMessage == String(repeating: "a", count: 500))
    #expect(result.lastUserMessage == "last message")
    #expect(result.lastActivityAt == expectedLastActivity)
  }

  @Test("Caps detected resource links to the newest fifty URLs")
  func capsDetectedResourceLinks() {
    let lines = (1...55).map { index in
      """
      {"type":"event_msg","timestamp":"2026-01-01T00:00:\(String(format: "%02d", index))Z","payload":{"type":"agent_message","message":"See https://codex\(index).example.dev/page for details"}}
      """
    }

    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines(lines, into: &result)

    let urls = result.detectedResourceLinks.map(\.url)
    #expect(urls.count == 50)
    #expect(!urls.contains("https://codex1.example.dev/page"))
    #expect(!urls.contains("https://codex5.example.dev/page"))
    #expect(urls.first == "https://codex6.example.dev/page")
    #expect(urls.last == "https://codex55.example.dev/page")
  }

  @Test("Extracts pull request URL from function call output before final text")
  func extractsPullRequestURLFromFunctionCallOutput() {
    let line = jsonLine([
      "type": "response_item",
      "timestamp": "2026-01-01T00:00:01.000Z",
      "payload": [
        "type": "function_call_output",
        "call_id": "call-1",
        "output": """
        {"url":"https://github.com/jamesrochabrun/AgentHub/pull/322","avatar_url":"https://avatars.githubusercontent.com/u/5378604"}
        """
      ]
    ])

    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedResourceLinks.map(\.url) == [
      "https://github.com/jamesrochabrun/AgentHub/pull/322"
    ])
  }

  @Test("Extracts pull request URL from MCP tool result")
  func extractsPullRequestURLFromMCPToolResult() {
    let line = jsonLine([
      "type": "event_msg",
      "timestamp": "2026-01-01T00:00:01.000Z",
      "payload": [
        "type": "mcp_tool_call_end",
        "result": [
          "Ok": [
            "content": [
              [
                "type": "text",
                "text": """
                {"url":"https://github.com/jamesrochabrun/AgentHub/pull/322","avatar_url":"https://avatars.githubusercontent.com/u/5378604"}
                """
              ]
            ]
          ]
        ]
      ]
    ])

    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedResourceLinks.map(\.url) == [
      "https://github.com/jamesrochabrun/AgentHub/pull/322"
    ])
  }
}

private func jsonLine(_ object: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: object)
  return String(decoding: data, as: UTF8.self)
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "codex_session_jsonl_parser_\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
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
