import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionJSONLParser retention")
struct SessionJSONLParserRetentionTests {

  @Test("Compacts older code change activities but keeps the newest five detailed")
  func compactsOlderCodeChangeActivities() {
    let lines = (1...7).map { index in
      """
      {"type":"assistant","timestamp":"2026-01-01T00:00:0\(index)Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"write-\(index)","name":"Write","input":{"file_path":"/tmp/File\(index).swift","content":"struct File\(index) {}"}}]}}
      """
    }

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(lines, into: &result)

    #expect(result.recentActivities.count == 7)

    let compactedInputs = result.recentActivities.prefix(2).compactMap(\.toolInput)
    #expect(compactedInputs.count == 2)
    #expect(compactedInputs.allSatisfy { $0.newString == nil })
    #expect(compactedInputs.allSatisfy { $0.toolType == .write })
    #expect(compactedInputs.map(\.filePath) == ["/tmp/File1.swift", "/tmp/File2.swift"])

    let retainedInputs = result.recentActivities.suffix(5).compactMap(\.toolInput)
    #expect(retainedInputs.count == 5)
    #expect(retainedInputs.allSatisfy { $0.newString != nil })
    #expect(result.pendingToolUses["write-1"]?.codeChangeInput?.newString == "struct File1 {}")
  }

  @Test("Caps detected resource links to the newest fifty URLs")
  func capsDetectedResourceLinks() {
    let lines = (1...55).map { index in
      """
      {"type":"assistant","timestamp":"2026-01-01T00:00:\(String(format: "%02d", index))Z","message":{"role":"assistant","content":[{"type":"text","text":"Reference https://example\(index).com/resource"}]}}
      """
    }

    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines(lines, into: &result)

    let urls = result.detectedResourceLinks.map(\.url)
    #expect(urls.count == 50)
    #expect(!urls.contains("https://example1.com/resource"))
    #expect(!urls.contains("https://example5.com/resource"))
    #expect(urls.first == "https://example6.com/resource")
    #expect(urls.last == "https://example55.com/resource")
  }
}
