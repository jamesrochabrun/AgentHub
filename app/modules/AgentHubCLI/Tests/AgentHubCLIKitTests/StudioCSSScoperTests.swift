import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("StudioCSSScoper")
struct StudioCSSScoperTests {
  private let scope = StudioCSSScoper.artboardSelector(forVariantName: "ghost")

  private func scoped(_ css: String, variant: String = "ghost") throws -> String {
    try StudioCSSScoper.scope(css, variantName: variant).css
  }

  @Test("Plain selectors are prefixed, including every member of a selector list")
  func plainSelectorsArePrefixed() throws {
    let out = try scoped("a, .b > c { color: red; }")
    #expect(out == "\(scope) a, \(scope) .b > c {\n  color: red;\n}")
  }

  @Test(":root, html, and body become the artboard itself")
  func rootSelectorsBecomeArtboard() throws {
    #expect(try scoped(":root { --x: 1; }") == "\(scope) {\n  --x: 1;\n}")
    #expect(try scoped("body { background: #111; }") == "\(scope) {\n  background: #111;\n}")
    #expect(try scoped("html { font-size: 14px; }") == "\(scope) {\n  font-size: 14px;\n}")
    #expect(try scoped("body.dark .card { color: white; }") == "\(scope).dark .card {\n  color: white;\n}")
    #expect(try scoped("body > .app { margin: 0; }") == "\(scope) > .app {\n  margin: 0;\n}")
  }

  @Test("`html body .x` collapses to one scope, not two")
  func htmlBodyCollapses() throws {
    #expect(try scoped("html body .x { top: 0; }") == "\(scope) .x {\n  top: 0;\n}")
    #expect(try scoped("html.dark body .x { top: 0; }") == "\(scope) .x {\n  top: 0;\n}")
  }

  @Test("`html, body` dedupes to a single artboard selector")
  func htmlBodyListDedupes() throws {
    #expect(try scoped("html, body { margin: 0; }") == "\(scope) {\n  margin: 0;\n}")
  }

  @Test("Tag names that merely start with body/html are ordinary selectors")
  func lookalikeTagsAreOrdinary() throws {
    #expect(try scoped("bodyguard { x: 1; }") == "\(scope) bodyguard {\n  x: 1;\n}")
    #expect(try scoped(".body { x: 1; }") == "\(scope) .body {\n  x: 1;\n}")
  }

  @Test("Universal selector is scoped beneath the artboard")
  func universalSelectorIsScoped() throws {
    #expect(try scoped("* { box-sizing: border-box; }") == "\(scope) * {\n  box-sizing: border-box;\n}")
  }

  @Test("Commas inside :is() and attribute selectors do not split the list")
  func nestedCommasDoNotSplit() throws {
    let out = try scoped(":is(h1, h2), [data-x=\"a,b\"] { m: 0; }")
    #expect(out == "\(scope) :is(h1, h2), \(scope) [data-x=\"a,b\"] {\n  m: 0;\n}")
  }

  @Test("@media, @supports, @container and @layer blocks recurse")
  func conditionalGroupsRecurse() throws {
    let out = try scoped("@media (max-width: 600px) { .a { x: 1; } body { y: 2; } }")
    #expect(out == "@media (max-width: 600px) {\n  \(scope) .a {\n    x: 1;\n  }\n  \(scope) {\n    y: 2;\n  }\n}")
    #expect(try scoped("@supports (display: grid) { .g { d: grid; } }").hasPrefix("@supports (display: grid) {\n  \(scope) .g"))
    #expect(try scoped("@container card (min-width: 400px) { .g { d: grid; } }").contains("\(scope) .g"))
    #expect(try scoped("@layer base { .g { d: grid; } }").contains("\(scope) .g"))
  }

  @Test("@keyframes are renamed per variant and animation references follow")
  func keyframesAreRenamed() throws {
    let out = try scoped("""
      .btn { animation: pulse 1s infinite, fade-in 300ms; }
      .x { animation-name: fade-in; }
      @keyframes pulse { from { opacity: 0 } to { opacity: 1 } }
      @keyframes fade-in { from { opacity: 0 } }
      """)
    #expect(out.contains("@keyframes pulse-ghost {"))
    #expect(out.contains("@keyframes fade-in-ghost {"))
    #expect(out.contains("animation: pulse-ghost 1s infinite, fade-in-ghost 300ms;"))
    #expect(out.contains("animation-name: fade-in-ghost;"))
    #expect(!out.contains("animation: pulse 1s"))
  }

  @Test("Keyframe renaming does not touch names that merely contain a keyframe name")
  func keyframeRenameIsWholeWord() throws {
    let out = try scoped(".a { animation: pulse-slow 1s; } @keyframes pulse { to { o: 1 } }")
    #expect(out.contains("animation: pulse-slow 1s;"))
  }

  @Test("@font-face is hoisted verbatim")
  func fontFaceIsVerbatim() throws {
    let out = try scoped("@font-face { font-family: X; src: url(x.woff2); }")
    #expect(out == "@font-face {\n  font-family: X; src: url(x.woff2);\n}")
    #expect(try StudioCSSScoper.scope("@font-face { font-family: X; }", variantName: "g").warnings.isEmpty)
  }

  @Test("@import is dropped with a warning; @charset silently")
  func importIsDroppedWithWarning() throws {
    let out = try StudioCSSScoper.scope("@charset \"utf-8\"; @import url(\"x.css\"); .a { b: c; }", variantName: "ghost")
    #expect(out.css == "\(scope) .a {\n  b: c;\n}")
    #expect(out.warnings.count == 1)
    #expect(out.warnings[0].contains("@import"))
  }

  @Test("!important, inline strings, and comments survive")
  func declarationsSurvive() throws {
    let out = try scoped("/* c */ .a { content: \"}\"; color: red !important; }")
    #expect(out == "\(scope) .a {\n  content: \"}\"; color: red !important;\n}")
  }

  @Test("Nested rules inside a style rule are kept relative to the scoped parent")
  func nestedRulesAreKept() throws {
    let out = try scoped(".a { color: red; &:hover { color: blue; } }")
    #expect(out == "\(scope) .a {\n  color: red; &:hover { color: blue; }\n}")
  }

  @Test("Unbalanced braces are a parse error carrying the offset")
  func unbalancedBracesThrow() {
    #expect(throws: StudioCSSScoper.ParseError.self) {
      try StudioCSSScoper.scope(".a { color: red;", variantName: "g")
    }
    #expect(throws: StudioCSSScoper.ParseError.self) {
      try StudioCSSScoper.scope(".a { color: red; } }", variantName: "g")
    }
    do {
      _ = try StudioCSSScoper.scope(".ok { x: 1; } .broken { y: 2;", variantName: "g")
      Issue.record("expected a parse error")
    } catch let error as StudioCSSScoper.ParseError {
      #expect(error.offset == 14)
      #expect(error.reason.contains("missing '}'"))
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  @Test("Two variants styling the same tag get disjoint selectors")
  func variantsGetDisjointSelectors() throws {
    let a = try scoped("button { color: red; }", variant: "A")
    let b = try scoped("button { color: blue; }", variant: "B")
    #expect(a.hasPrefix(".studio-artboard[data-variant=\"A\"] button"))
    #expect(b.hasPrefix(".studio-artboard[data-variant=\"B\"] button"))
    #expect(a != b)
  }

  @Test("Variant names are escaped in the attribute selector and slugged for identifiers")
  func namesAreEscapedAndSlugged() {
    #expect(StudioCSSScoper.artboardSelector(forVariantName: "say \"hi\"") == ".studio-artboard[data-variant=\"say \\\"hi\\\"\"]")
    #expect(StudioCSSScoper.slug("Primary CTA (v2)") == "primary-cta-v2")
    #expect(StudioCSSScoper.slug("!!!") == "variant")
  }

  @Test("Empty CSS scopes to empty output")
  func emptyCSS() throws {
    #expect(try scoped("") == "")
    #expect(try scoped("   \n /* nothing */ ") == "")
  }
}
