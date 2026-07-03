import Foundation
import JavaScriptCore
import Testing

@testable import AgentHubCore

@Suite("WebPreviewStyleProvenanceScript")
struct WebPreviewStyleProvenanceScriptTests {

  @Test("The generated script is syntactically valid JavaScript")
  func scriptParsesAsJavaScript() throws {
    let script = try #require(WebPreviewStyleProvenanceScript.script(
      selector: ".cta > button:nth-of-type(2)",
      properties: ["color", "line-height"]
    ))

    let context = try #require(JSContext())
    context.exceptionHandler = { _, exception in
      Issue.record("Script failed to parse: \(exception?.toString() ?? "unknown")")
    }
    context.evaluateScript("new Function(\(jsStringLiteral(script)));")
  }

  @Test("Selector and properties are embedded as escaped JSON")
  func embedsEscapedInputs() throws {
    let script = try #require(WebPreviewStyleProvenanceScript.script(
      selector: #"button[data-label="Launch \"now\""]"#,
      properties: ["background-color"]
    ))

    #expect(script.contains("var SELECTOR = \"button[data-label="))
    #expect(script.contains("var PROPERTIES = [\"background-color\"]"))
    #expect(!script.contains("__PLACEHOLDER__"))
  }

  @Test("A selector that would break out of a string literal cannot inject code")
  func selectorCannotInjectCode() throws {
    let script = try #require(WebPreviewStyleProvenanceScript.script(
      selector: "\"; window.__pwned = true; var x = \"",
      properties: ["color"]
    ))

    let context = try #require(JSContext())
    context.evaluateScript("var window = {}; var document = { querySelector: function() { return null; } };")
    context.evaluateScript(script)
    #expect(context.evaluateScript("window.__pwned").isUndefined)
  }

  @Test("The script returns element-not-found for unmatched selectors")
  func returnsElementNotFound() throws {
    let script = try #require(WebPreviewStyleProvenanceScript.script(
      selector: ".missing",
      properties: ["color"]
    ))

    let context = try #require(JSContext())
    context.evaluateScript("var window = {}; var document = { querySelector: function() { return null; } };")
    let result = context.evaluateScript(script)
    #expect(result?.toDictionary()?["ok"] as? Bool == false)
    #expect(result?.toDictionary()?["reason"] as? String == "element-not-found")
  }
}

private func jsStringLiteral(_ value: String) -> String {
  let data = try? JSONSerialization.data(withJSONObject: [value])
  let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
  return String(wrapped.dropFirst().dropLast())
}

@Suite("WebPreviewStyleProvenance parsing")
struct WebPreviewStyleProvenanceParsingTests {

  @Test("Parses winners, rules, and flags from the script payload")
  func parsesWinnerPayload() {
    let payload: [String: Any] = [
      "ok": true,
      "hasAdoptedSheets": false,
      "unreadableSheets": ["http://localhost/skipped.css"],
      "winners": [
        [
          "property": "line-height",
          "declaredValue": "26px",
          "isInline": false,
          "isImportant": false,
          "flags": [],
          "rule": [
            "stylesheetHref": "http://localhost:5173/src/styles.css",
            "styleSheetIndex": 0,
            "ruleIndexPath": [1, 0],
            "selectorText": ".cta",
            "specificity": [0, 1, 0],
            "ownerNodeAttributes": ["data-vite-dev-id": "/project/src/styles.css"],
          ],
        ],
        [
          "property": "color",
          "declaredValue": "red",
          "isInline": true,
          "isImportant": false,
          "flags": ["layer", "not-a-real-flag"],
          "rule": NSNull(),
        ],
      ],
    ]

    let provenance = WebPreviewStyleProvenance.parse(payload)

    #expect(provenance?.winners.count == 2)
    #expect(provenance?.unreadableSheetHrefs == ["http://localhost/skipped.css"])

    let lineHeight = provenance?.winner(for: "line-height")
    #expect(lineHeight?.isProvable == true)
    #expect(lineHeight?.rule?.ruleIndexPath == [1, 0])
    #expect(lineHeight?.rule?.ownerNodeAttributes["data-vite-dev-id"] == "/project/src/styles.css")

    let color = provenance?.winner(for: "color")
    #expect(color?.isInline == true)
    #expect(color?.isProvable == false)
    #expect(color?.uncertainties == [.layer])
  }

  @Test("Uncertainty flags make a winner unprovable")
  func flaggedWinnersAreUnprovable() {
    let payload: [String: Any] = [
      "ok": true,
      "winners": [
        [
          "property": "color",
          "declaredValue": "red",
          "isInline": false,
          "flags": ["unreadableSheet"],
          "rule": [
            "stylesheetHref": "file:///project/site.css",
            "styleSheetIndex": 0,
            "ruleIndexPath": [0],
            "selectorText": ".a",
            "specificity": [0, 1, 0],
          ],
        ]
      ],
    ]

    let provenance = WebPreviewStyleProvenance.parse(payload)
    #expect(provenance?.winner(for: "color")?.isProvable == false)
  }

  @Test("Non-ok and malformed payloads parse to nil")
  func malformedPayloadsAreNil() {
    #expect(WebPreviewStyleProvenance.parse(nil) == nil)
    #expect(WebPreviewStyleProvenance.parse(["ok": false]) == nil)
    #expect(WebPreviewStyleProvenance.parse("nope") == nil)
  }
}
