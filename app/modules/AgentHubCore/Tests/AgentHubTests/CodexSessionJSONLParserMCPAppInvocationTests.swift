import AgentHubMCPUI
import Foundation
import Testing

@testable import AgentHubCore

@Suite("CodexSessionJSONLParser MCP app invocation capture")
struct CodexSessionJSONLParserMCPAppInvocationTests {
  @Test("Captures an MCP tool call from a single mcp_tool_call_end event")
  func capturesInvocationFromMCPToolCallEnd() {
    // Codex emits invocation (server/tool/arguments) and the Ok-wrapped result together.
    let line = """
      {"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"mcp_tool_call_end","call_id":"call-1","invocation":{"server":"excalidraw","tool":"create_view","arguments":{"elements":"[{\\"type\\":\\"text\\",\\"text\\":\\"Login Flow\\"}]"}},"result":{"Ok":{"content":[{"type":"text","text":"{\\"checkpointId\\":\\"abc123\\"}"}]}}}}
      """
    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedMCPAppInvocations.count == 1)
    let invocation = result.detectedMCPAppInvocations.first
    #expect(invocation?.id == "call-1")
    #expect(invocation?.serverName == "excalidraw")
    #expect(invocation?.toolName == "create_view")
    #expect(invocation?.arguments?["elements"]?.stringValue?.contains("Login Flow") == true)
    // The Ok envelope is unwrapped to the raw MCP result.
    #expect(invocation?.result?["content"]?.arrayValue?.first?["text"]?.stringValue == "{\"checkpointId\":\"abc123\"}")
  }

  @Test("Ignores mcp_tool_call_end without a server/tool invocation")
  func ignoresInvocationWithoutServerOrTool() {
    let line = """
      {"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"mcp_tool_call_end","call_id":"call-1","result":{"Ok":{"content":[]}}}}
      """
    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedMCPAppInvocations.isEmpty)
  }

  @Test("Unwraps an Err result envelope")
  func unwrapsErrResult() {
    let line = """
      {"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"mcp_tool_call_end","call_id":"call-2","invocation":{"server":"excalidraw","tool":"create_view","arguments":{}},"result":{"Err":{"message":"boom"}}}}
      """
    var result = CodexSessionJSONLParser.ParseResult()
    CodexSessionJSONLParser.parseNewLines([line], into: &result)

    #expect(result.detectedMCPAppInvocations.count == 1)
    #expect(result.detectedMCPAppInvocations.first?.result?["message"]?.stringValue == "boom")
  }
}
