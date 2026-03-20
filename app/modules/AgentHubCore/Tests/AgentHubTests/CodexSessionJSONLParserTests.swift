import Foundation
import Testing

@testable import AgentHubCore

@Suite("CodexSessionJSONLParser")
struct CodexSessionJSONLParserTests {

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
}
