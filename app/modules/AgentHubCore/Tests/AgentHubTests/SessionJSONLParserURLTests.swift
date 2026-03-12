import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionJSONLParser URL extraction")
struct SessionJSONLParserURLTests {

  // MARK: - tool_use input URL extraction

  @Test("Extracts URL from WebFetch tool_use input")
  func extractsURLFromToolUseInput() {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"WebFetch","input":{"url":"https://example.com/page","prompt":"summarize"}}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedResourceLinks.count == 1)
    #expect(result.detectedResourceLinks[0].url == "https://example.com/page")
  }

  @Test("Does not duplicate URL already seen in tool_use")
  func noDuplicateFromToolUse() {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"WebFetch","input":{"url":"https://example.com"}},{"type":"tool_use","id":"tu2","name":"WebFetch","input":{"url":"https://example.com"}}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedResourceLinks.count == 1)
  }

  @Test("Ignores tool_use with no url key in input")
  func ignoresToolUseWithNoURL() {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls -la"}}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedResourceLinks.isEmpty)
  }

  // MARK: - tool_result content URL extraction

  @Test("Extracts URL from tool_result with String content")
  func extractsURLFromToolResultStringContent() {
    let assistantLine = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"WebFetch","input":{"url":"https://example.com"}}]}}
      """
    let userLine = """
      {"type":"user","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Fetched https://docs.example.com/api successfully"}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([assistantLine, userLine], into: &result)

    let urls = result.detectedResourceLinks.map { $0.url }
    #expect(urls.contains("https://example.com"))
    #expect(urls.contains("https://docs.example.com/api"))
  }

  @Test("Extracts URL from tool_result with array content")
  func extractsURLFromToolResultArrayContent() {
    let assistantLine = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"web_search","input":{"query":"swift concurrency"}}]}}
      """
    let userLine = """
      {"type":"user","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":[{"type":"text","text":"Result: https://swift.org/concurrency and https://developer.apple.com/swift"}]}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([assistantLine, userLine], into: &result)

    let urls = result.detectedResourceLinks.map { $0.url }
    #expect(urls.contains("https://swift.org/concurrency"))
    #expect(urls.contains("https://developer.apple.com/swift"))
  }

  @Test("Does not duplicate URL seen in both tool_use and tool_result")
  func noDuplicateAcrossToolUseAndResult() {
    let assistantLine = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"WebFetch","input":{"url":"https://example.com"}}]}}
      """
    let userLine = """
      {"type":"user","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"Fetched https://example.com successfully"}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([assistantLine, userLine], into: &result)

    let count = result.detectedResourceLinks.filter { $0.url == "https://example.com" }.count
    #expect(count == 1)
  }

  // MARK: - URL accumulation across multiple messages

  @Test("Accumulates URLs across multiple incremental parse calls")
  func accumulatesURLsAcrossIncrementalCalls() {
    let line1 = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"WebFetch","input":{"url":"https://first.com"}}]}}
      """
    let line2 = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"WebFetch","input":{"url":"https://second.com"}}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line1], into: &result)
    SessionJSONLParser.parseNewLines([line2], into: &result)

    let urls = result.detectedResourceLinks.map { $0.url }
    #expect(urls.contains("https://first.com"))
    #expect(urls.contains("https://second.com"))
    #expect(result.detectedResourceLinks.count == 2)
  }

  // MARK: - Existing text block extraction still works

  @Test("Still extracts URLs from assistant text blocks")
  func stillExtractsURLsFromTextBlocks() {
    let line = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"Check out https://example.com for more info"}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedResourceLinks.count == 1)
    #expect(result.detectedResourceLinks[0].url == "https://example.com")
  }
}
