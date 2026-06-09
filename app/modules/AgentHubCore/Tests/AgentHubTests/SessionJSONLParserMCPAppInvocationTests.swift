import AgentHubMCPUI
import Foundation
import Testing

@testable import AgentHubCore

@Suite("SessionJSONLParser MCP app invocation capture")
struct SessionJSONLParserMCPAppInvocationTests {
  @Test("Captures an mcp__ tool call's input and result as an invocation")
  func capturesMCPToolInvocation() {
    let assistantLine = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"mcp__excalidraw__create_view","input":{"elements":[{"type":"rectangle"}]}}]}}
      """
    let userLine = """
      {"type":"user","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"{\\"checkpointId\\":\\"abc123\\"}"}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([assistantLine, userLine], into: &result)

    #expect(result.pendingMCPInvocations.isEmpty)
    #expect(result.detectedMCPAppInvocations.count == 1)

    let invocation = result.detectedMCPAppInvocations.first
    #expect(invocation?.id == "tu1")
    #expect(invocation?.serverName == "excalidraw")
    #expect(invocation?.toolName == "create_view")
    #expect(invocation?.arguments?["elements"]?.arrayValue?.count == 1)
    #expect(invocation?.result?.stringValue == "{\"checkpointId\":\"abc123\"}")
  }

  @Test("Does not capture invocations for non-MCP tools")
  func ignoresNonMCPTools() {
    let assistantLine = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]}}
      """
    let userLine = """
      {"type":"user","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"file.txt"}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([assistantLine, userLine], into: &result)

    #expect(result.detectedMCPAppInvocations.isEmpty)
  }

  @Test("An in-flight MCP tool call is pending until its result arrives")
  func pendingUntilResult() {
    let assistantLine = """
      {"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"mcp__excalidraw__create_view","input":{"elements":[]}}]}}
      """
    var result = SessionJSONLParser.ParseResult()
    SessionJSONLParser.parseNewLines([assistantLine], into: &result)

    #expect(result.detectedMCPAppInvocations.isEmpty)
    #expect(result.pendingMCPInvocations["tu1"]?.serverName == "excalidraw")
  }

  @Test("Parses the server tool short name from a fully-qualified MCP tool name")
  func parsesShortToolName() {
    #expect(SessionJSONLParser.mcpToolShortName(fromToolName: "mcp__excalidraw__create_view") == "create_view")
    #expect(SessionJSONLParser.mcpToolShortName(fromToolName: "mcp__server__a__b") == "a__b")
    #expect(SessionJSONLParser.mcpToolShortName(fromToolName: "Bash") == "Bash")
  }
}
