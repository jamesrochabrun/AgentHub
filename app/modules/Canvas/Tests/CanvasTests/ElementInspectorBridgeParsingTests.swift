import CoreGraphics
import Testing
@testable import Canvas

@Suite("ElementInspectorBridge parsing")
struct ElementInspectorBridgeParsingTests {

  @Test func parsesFullyPopulatedDictionary() {
    let dict: [String: Any] = [
      "tagName": "BUTTON",
      "elementId": "submit",
      "className": "btn primary",
      "textContent": "Go",
      "outerHTML": "<button>Go</button>",
      "cssSelector": "form > button",
      "computedStyles": ["color": "red", "fontSize": "14px"],
      "boundingRect": ["x": 10.0, "y": 20.0, "width": 100.0, "height": 40.0],
    ]
    let data = ElementInspectorBridge.parseElementData(dict)
    #expect(data.tagName == "BUTTON")
    #expect(data.elementId == "submit")
    #expect(data.className == "btn primary")
    #expect(data.textContent == "Go")
    #expect(data.outerHTML == "<button>Go</button>")
    #expect(data.cssSelector == "form > button")
    #expect(data.computedStyles == ["color": "red", "fontSize": "14px"])
    #expect(data.boundingRect == CGRect(x: 10, y: 20, width: 100, height: 40))
  }

  @Test func missingKeysDefaultToEmptyStringsAndZeroRect() {
    let data = ElementInspectorBridge.parseElementData([:])
    #expect(data.tagName == "")
    #expect(data.elementId == "")
    #expect(data.className == "")
    #expect(data.textContent == "")
    #expect(data.outerHTML == "")
    #expect(data.cssSelector == "")
    #expect(data.computedStyles == [:])
    #expect(data.boundingRect == .zero)
  }

  @Test func partialBoundingRectFillsMissingWithZero() {
    let dict: [String: Any] = [
      "boundingRect": ["x": 5.0, "height": 30.0],
    ]
    let data = ElementInspectorBridge.parseElementData(dict)
    #expect(data.boundingRect == CGRect(x: 5, y: 0, width: 0, height: 30))
  }

  @Test func parsesSelectionRectMessage() {
    let rect = ElementInspectorBridge.parseSelectionRect([
      "type": "selectionRect",
      "boundingRect": ["x": 9.0, "y": 11.0, "width": 120.0, "height": 32.0],
    ])

    #expect(rect == CGRect(x: 9, y: 11, width: 120, height: 32))
  }

  @Test func missingSelectionRectDefaultsToZero() {
    let rect = ElementInspectorBridge.parseSelectionRect(["type": "selectionRect"])
    #expect(rect == .zero)
  }

  @Test func missingComputedStylesDefaultsToEmptyDict() {
    let data = ElementInspectorBridge.parseElementData([:])
    #expect(data.computedStyles.isEmpty)
  }

  @Test func wrongTypeComputedStylesDefaultsToEmptyDict() {
    let dict: [String: Any] = [
      "computedStyles": "not a dictionary",
    ]
    let data = ElementInspectorBridge.parseElementData(dict)
    #expect(data.computedStyles.isEmpty)
  }

  @Test func wrongTypeBoundingRectDefaultsToZeroRect() {
    let dict: [String: Any] = [
      "boundingRect": "not a dictionary",
    ]
    let data = ElementInspectorBridge.parseElementData(dict)
    #expect(data.boundingRect == .zero)
  }

  @Test func wrongTypeStringFieldsDefaultToEmptyString() {
    let dict: [String: Any] = [
      "tagName": 42,
      "elementId": true,
      "className": 3.14,
    ]
    let data = ElementInspectorBridge.parseElementData(dict)
    #expect(data.tagName == "")
    #expect(data.elementId == "")
    #expect(data.className == "")
  }

  @Test func eachCallGeneratesUniqueUUID() {
    let a = ElementInspectorBridge.parseElementData([:])
    let b = ElementInspectorBridge.parseElementData([:])
    #expect(a.id != b.id)
  }
}
