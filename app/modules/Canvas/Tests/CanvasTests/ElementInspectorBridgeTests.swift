import Testing

@testable import Canvas

@Suite("ElementInspectorBridge")
struct ElementInspectorBridgeTests {
  @Test("Parses pane change payloads into typed inspector changes")
  func parsesPaneChangePayloads() {
    let payload: [String: Any] = [
      "type": "paneChange",
      "property": "font-size",
      "value": "18"
    ]

    let change = ElementInspectorBridge.parsePaneChange(payload)

    #expect(change == CanvasInspectorChange(property: "font-size", value: "18"))
  }

  @Test("Returns nil for malformed pane change payloads")
  func rejectsMalformedPaneChangePayloads() {
    let payload: [String: Any] = [
      "type": "paneChange",
      "property": "font-size"
    ]

    let change = ElementInspectorBridge.parsePaneChange(payload)

    #expect(change == nil)
  }
}
