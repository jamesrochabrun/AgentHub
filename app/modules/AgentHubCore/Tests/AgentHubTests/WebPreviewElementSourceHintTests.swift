import Foundation
import JavaScriptCore
import Testing

@testable import AgentHubCore

@Suite("WebPreviewSourceHintScript")
struct WebPreviewSourceHintScriptTests {

  @Test("The generated script is syntactically valid JavaScript")
  func scriptParsesAsJavaScript() throws {
    let script = try #require(WebPreviewSourceHintScript.script(selector: ".cta > button"))

    let context = try #require(JSContext())
    context.exceptionHandler = { _, exception in
      Issue.record("Script failed to parse: \(exception?.toString() ?? "unknown")")
    }
    context.evaluateScript("new Function(\(jsLiteral(script)));")
  }

  @Test("A hostile selector cannot escape the embedded string literal")
  func selectorCannotInjectCode() throws {
    let script = try #require(WebPreviewSourceHintScript.script(
      selector: "\"; globalThis.__pwned = true; var x = \""
    ))

    let context = try #require(JSContext())
    context.evaluateScript("var document = { querySelector: function() { return null; } };")
    context.evaluateScript(script)
    #expect(context.evaluateScript("globalThis.__pwned").isUndefined)
  }

  @Test("Svelte metadata and generic attributes are extracted")
  func extractsSvelteAndAttributeHints() throws {
    let script = try #require(WebPreviewSourceHintScript.script(selector: ".cta"))

    let context = try #require(JSContext())
    context.evaluateScript("""
      var el = {
        __svelte_meta: { loc: { file: 'src/lib/Button.svelte', line: 12, column: 4 } },
        parentElement: null,
        getAttribute: function(name) {
          if (name === 'data-source-loc') { return 'src/App.tsx:8:2'; }
          return null;
        }
      };
      var document = { querySelector: function() { return el; } };
    """)
    let result = context.evaluateScript(script)
    let hints = WebPreviewElementSourceHint.parse(result?.toDictionary())

    #expect(hints.contains(WebPreviewElementSourceHint(
      kind: .svelteMeta, file: "src/lib/Button.svelte", line: 12, column: 4, detail: nil
    )))
    #expect(hints.contains(WebPreviewElementSourceHint(
      kind: .genericAttribute, file: "src/App.tsx", line: 8, column: 2, detail: "data-source-loc"
    )))
  }

  @Test("React owner chains are extracted when _debugSource is absent")
  func extractsReactOwnerChain() throws {
    let script = try #require(WebPreviewSourceHintScript.script(selector: ".cta"))

    let context = try #require(JSContext())
    context.evaluateScript("""
      var fiber = {
        _debugOwner: {
          type: { name: 'CardButton' },
          _debugOwner: { type: { displayName: 'Card' }, _debugOwner: null }
        }
      };
      var el = {
        parentElement: null,
        getAttribute: function() { return null; }
      };
      el['__reactFiber$abc123'] = fiber;
      var document = { querySelector: function() { return el; } };
    """)
    let result = context.evaluateScript(script)
    let hints = WebPreviewElementSourceHint.parse(result?.toDictionary())

    #expect(hints == [WebPreviewElementSourceHint(
      kind: .reactOwnerChain, file: nil, line: nil, column: nil,
      detail: "component chain: Card > CardButton"
    )])
  }
}

private func jsLiteral(_ value: String) -> String {
  let data = try? JSONSerialization.data(withJSONObject: [value])
  let wrapped = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
  return String(wrapped.dropFirst().dropLast())
}

@Suite("WebPreviewElementSourceHint parsing")
struct WebPreviewElementSourceHintParsingTests {

  @Test("Parses hint payloads and drops unknown kinds")
  func parsesPayload() {
    let payload: [String: Any] = [
      "ok": true,
      "hints": [
        ["kind": "svelteMeta", "file": "src/App.svelte", "line": 3, "column": 1],
        ["kind": "vueInspector", "file": "src/App.vue", "line": 7, "column": 2, "detail": "ancestor"],
        ["kind": "made-up-kind", "file": "x"],
        ["kind": "reactOwnerChain", "detail": "component chain: App > Button"],
      ],
    ]

    let hints = WebPreviewElementSourceHint.parse(payload)

    #expect(hints.count == 3)
    #expect(hints[0].promptLine == "src/App.svelte:3:1 (svelte)")
    #expect(hints[1].promptLine == "src/App.vue:7:2 (vue)")
    #expect(hints[2].promptLine == "component chain: App > Button (react)")
  }

  @Test("Malformed payloads parse to an empty list")
  func malformedPayloadsAreEmpty() {
    #expect(WebPreviewElementSourceHint.parse(nil).isEmpty)
    #expect(WebPreviewElementSourceHint.parse(["ok": false, "hints": []]).isEmpty)
    #expect(WebPreviewElementSourceHint.parse(["ok": true]).isEmpty)
  }
}
