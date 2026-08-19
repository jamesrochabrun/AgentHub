import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("StudioTweakProps")
struct StudioTweakPropsTests {
  private func json(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
  }

  @Test("Parses every type from a name-keyed object, sorted by name")
  func parsesEveryType() throws {
    let props = try StudioTweakPropParser.parse(try json("""
      {
        "radius": { "type": "slider", "value": 12, "min": 0, "max": 32, "step": 2, "unit": "px", "label": "Corner radius" },
        "accent": { "type": "color", "value": "#0a84ff" },
        "weight": { "type": "select", "value": "600", "options": ["400", "600", "700"] },
        "shadow": { "type": "toggle", "value": true },
        "cta":    { "type": "text", "value": "Continue" }
      }
      """))
    #expect(props.map(\.name) == ["accent", "cta", "radius", "shadow", "weight"])
    let radius = try #require(props.first { $0.name == "radius" })
    #expect(radius.type == .slider)
    #expect(radius.value == .number(12))
    #expect(radius.minimum == 0 && radius.maximum == 32 && radius.step == 2)
    #expect(radius.unit == "px")
    #expect(radius.label == "Corner radius")
    #expect(radius.cssValue == "12px")
    #expect(radius.cssVariableName == "--radius")
    #expect(props.first { $0.name == "shadow" }?.cssValue == "1")
    #expect(props.first { $0.name == "weight" }?.options == ["400", "600", "700"])
    #expect(props.first { $0.name == "cta" }?.label == "cta")
  }

  @Test("An array form preserves declaration order")
  func arrayPreservesOrder() throws {
    let props = try StudioTweakPropParser.parse(try json("""
      [ { "name": "zeta", "type": "toggle", "value": false }, { "name": "alpha", "type": "text", "value": "x" } ]
      """))
    #expect(props.map(\.name) == ["zeta", "alpha"])
  }

  @Test("JSON true/false and 1/0 are told apart")
  func booleansVersusNumbers() throws {
    let props = try StudioTweakPropParser.parse(try json("""
      { "size": { "type": "slider", "value": 1 }, "on": { "type": "toggle", "value": true } }
      """))
    #expect(props.first { $0.name == "size" }?.value == .number(1))
    #expect(props.first { $0.name == "on" }?.value == .boolean(true))
    #expect(throws: StudioTweakPropParser.ValidationError.self) {
      _ = try StudioTweakPropParser.parse(try json("{ \"on\": { \"type\": \"toggle\", \"value\": 1 } }"))
    }
  }

  @Test("Rejects bad names, unknown types, mismatched values, selects without options, out-of-range sliders")
  func rejectsInvalid() throws {
    let bad: [String] = [
      "{ \"1st\": { \"type\": \"text\", \"value\": \"x\" } }",
      "{ \"has space\": { \"type\": \"text\", \"value\": \"x\" } }",
      "{ \"x\": { \"type\": \"knob\", \"value\": 1 } }",
      "{ \"x\": { \"type\": \"slider\", \"value\": \"big\" } }",
      "{ \"x\": { \"type\": \"select\", \"value\": \"a\" } }",
      "{ \"x\": { \"type\": \"select\", \"value\": \"c\", \"options\": [\"a\", \"b\"] } }",
      "{ \"x\": { \"type\": \"slider\", \"value\": 50, \"min\": 0, \"max\": 10 } }",
      "{ \"x\": { \"type\": \"slider\", \"value\": 5, \"min\": 10, \"max\": 0 } }",
      "{ \"x\": \"not an object\" }",
      "[ { \"type\": \"text\", \"value\": \"no name\" } ]",
    ]
    for text in bad {
      #expect(throws: StudioTweakPropParser.ValidationError.self, "\(text)") {
        _ = try StudioTweakPropParser.parse(try json(text))
      }
    }
    #expect(throws: StudioTweakPropParser.ValidationError.self) {
      _ = try StudioTweakPropParser.parse("nope")
    }
    #expect(try StudioTweakPropParser.parse(nil).isEmpty)
    #expect(try StudioTweakPropParser.parse(NSNull()).isEmpty)
  }

  @Test("Unused props are detected by CSS variable or data-prop reference")
  func unusedProps() {
    let props = [
      StudioTweakProp(name: "radius", type: .slider, value: .number(1)),
      StudioTweakProp(name: "cta", type: .text, value: .string("Go")),
      StudioTweakProp(name: "ghost", type: .toggle, value: .boolean(true)),
    ]
    let variants = [
      StudioVariant(name: "a", html: "<button data-prop=\"cta\">Go</button>", css: ".b { border-radius: var(--radius, 4px); }"),
      StudioVariant(name: "b", html: "<i style=\"opacity: var(--radius)\">x</i>", css: ""),
    ]
    #expect(StudioTweakPropParser.unusedProps(props, variants: variants) == ["ghost"])
    #expect(StudioTweakPropParser.unusedProps([], variants: variants).isEmpty)
  }

  @Test("Too many props is rejected")
  func tooMany() throws {
    let entries = (0..<(StudioTweakPropParser.maxProps + 1)).map { "\"p\($0)\": { \"type\": \"text\", \"value\": \"x\" }" }
    #expect(throws: StudioTweakPropParser.ValidationError.self) {
      _ = try StudioTweakPropParser.parse(try json("{ \(entries.joined(separator: ",")) }"))
    }
  }

  @Test("CSS values: fractional sliders, unitless numbers, raw strings")
  func cssValues() {
    #expect(StudioTweakProp(name: "o", type: .slider, value: .number(0.5)).cssValue == "0.5")
    #expect(StudioTweakProp(name: "o", type: .slider, value: .number(2), unit: "rem").cssValue == "2rem")
    #expect(StudioTweakProp(name: "c", type: .color, value: .string("rgb(1 2 3)")).cssValue == "rgb(1 2 3)")
    #expect(StudioTweakProp(name: "t", type: .toggle, value: .boolean(false)).cssValue == "0")
    #expect(StudioTweakProp(name: "t", type: .toggle, value: .boolean(false)).cssValue(for: .boolean(true)) == "1")
  }

  @Test("Props round-trip through Codable and older payloads without props still decode")
  func codable() throws {
    let artifact = makeCanvas(id: "c").withContent(props: [
      StudioTweakProp(name: "radius", type: .slider, value: .number(12), minimum: 0, maximum: 32, unit: "px"),
      StudioTweakProp(name: "on", type: .toggle, value: .boolean(true)),
      StudioTweakProp(name: "cta", type: .text, value: .string("Go")),
    ])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(artifact)
    #expect(try decoder.decode(StudioArtifact.self, from: data) == artifact)

    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "props")
    object.removeValue(forKey: "warnings")
    let legacy = try decoder.decode(StudioArtifact.self, from: try JSONSerialization.data(withJSONObject: object))
    #expect(legacy.props.isEmpty)
    #expect(legacy.warnings.isEmpty)
    #expect(legacy.id == "c")

    // Declaration is what the host page hands to dc_set_props.
    let declaration = artifact.props[0].declaration
    #expect(declaration["type"] as? String == "slider")
    #expect(declaration["unit"] as? String == "px")
    #expect((declaration["value"] as? Double) == 12)
  }
}
