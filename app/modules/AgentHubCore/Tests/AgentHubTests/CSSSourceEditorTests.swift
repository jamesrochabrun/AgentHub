import Foundation
import Testing

@testable import AgentHubCore

@Suite("CSSSourceEditor")
struct CSSSourceEditorTests {
  private let editor = CSSSourceEditor()

  // MARK: - Parsing

  @Test("Parses top-level rules with CSSOM-compatible index paths")
  func parsesTopLevelRules() throws {
    let source = """
    /* header */
    .a { color: red; }
    @media (min-width: 600px) {
      .b { color: blue; }
    }
    .c { color: green; }
    """

    let document = try editor.parse(source)

    #expect(document.rules.count == 3)
    #expect(document.rules[0].normalizedSelectorText == ".a")
    #expect(document.rules[1].isAtRule)
    #expect(document.rules[1].children.count == 1)
    #expect(document.rule(at: [1, 0])?.normalizedSelectorText == ".b")
    #expect(document.rule(at: [2])?.normalizedSelectorText == ".c")
    #expect(document.rule(at: [3]) == nil)
    #expect(document.rule(at: [1, 1]) == nil)
  }

  @Test("Statement at-rules occupy an index like CSSOM cssRules")
  func statementAtRulesAreIndexed() throws {
    let source = """
    @import url("base.css");
    .a { color: red; }
    """

    let document = try editor.parse(source)

    #expect(document.rules.count == 2)
    #expect(document.rules[0].isAtRule)
    #expect(document.rules[0].prelude.hasPrefix("@import"))
    #expect(document.rule(at: [1])?.normalizedSelectorText == ".a")
  }

  @Test("Braces and semicolons inside strings, url(), and comments are ignored")
  func ignoresBracesInStringsAndComments() throws {
    let source = """
    .a {
      background: url(image;with{weird}.png);
      content: "not a } brace; really";
      /* color: fake; } { */
      color: red;
    }
    .b { color: blue; }
    """

    let document = try editor.parse(source)

    #expect(document.rules.count == 2)
    let declarations = document.rules[0].declarations
    #expect(declarations.map(\.name) == ["background", "content", "color"])
    #expect(declarations[2].valueText == "red")
  }

  @Test("Parses !important, custom properties, and a trailing declaration without a semicolon")
  func parsesImportantAndTrailingDeclaration() throws {
    let source = ".a { --brand: #fff; color: red !important; padding: 4px }"

    let document = try editor.parse(source)
    let declarations = document.rules[0].declarations

    #expect(declarations.count == 3)
    #expect(declarations[0].name == "--brand")
    #expect(declarations[1].isImportant)
    #expect(declarations[1].valueText == "red")
    #expect(declarations[2].name == "padding")
    #expect(!declarations[2].hasTrailingSemicolon)
  }

  @Test("CSS nesting produces child rules and mixed declarations")
  func parsesNestedRules() throws {
    let source = """
    .card {
      color: black;
      &:hover { color: blue; }
      .inner { color: gray; }
    }
    """

    let document = try editor.parse(source)
    let card = document.rules[0]

    #expect(card.declarations.map(\.name) == ["color"])
    #expect(card.children.count == 2)
    #expect(document.rule(at: [0, 0])?.prelude == "&:hover")
    #expect(document.rule(at: [0, 1])?.normalizedSelectorText == ".inner")
  }

  @Test("Unbalanced braces fail to parse")
  func unbalancedBracesFail() {
    #expect(throws: CSSSourceEditorError.self) {
      _ = try editor.parse(".a { color: red;")
    }
    #expect(throws: CSSSourceEditorError.self) {
      _ = try editor.parse(".a { color: red; } }")
    }
  }

  @Test("Selector normalization collapses whitespace and combinator spacing")
  func selectorNormalization() {
    #expect(CSSSourceEditor.normalizeSelector("  .a  >  .b ,\n .C  ") == ".a>.b,.c")
    #expect(CSSSourceEditor.normalizeSelector("DIV .cta") == "div .cta")
  }

  // MARK: - Editing

  @Test("Replacing a value changes only that declaration's bytes")
  func replaceValuePreservesEverythingElse() throws {
    let source = """
    /* keep this comment */
    .cta {
    \tcolor: #ffffff;
    \tline-height: 26px; /* trailing */
    }

    .other { color: red; }
    """

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "line-height", value: "30px"),
      to: source
    )

    #expect(edited == source.replacingOccurrences(of: "line-height: 26px;", with: "line-height: 30px;"))
  }

  @Test("Replacing an !important value preserves the importance")
  func replaceImportantValueKeepsImportance() throws {
    let source = ".a { color: red !important; }"

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "color", value: "blue"),
      to: source
    )

    #expect(edited == ".a { color: blue !important; }")
  }

  @Test("Inserting a new declaration reuses the rule's indentation")
  func insertMatchesIndentation() throws {
    let source = """
    .cta {
        color: red;
    }
    """

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "padding", value: "12px"),
      to: source
    )

    #expect(edited == """
    .cta {
        color: red;
        padding: 12px;
    }
    """)
  }

  @Test("Inserting after a declaration without a trailing semicolon first adds one")
  func insertAfterUnterminatedDeclaration() throws {
    let source = ".cta { color: red }"

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "padding", value: "12px"),
      to: source
    )

    let document = try editor.parse(edited)
    #expect(document.rules[0].declarations.map(\.name) == ["color", "padding"])
    #expect(document.rules[0].declarations[1].valueText == "12px")
  }

  @Test("Editing a rule inside a media query targets the nested rule only")
  func editInsideMediaQuery() throws {
    let source = """
    .cta { font-size: 14px; }
    @media (min-width: 600px) {
      .cta { font-size: 18px; }
    }
    """

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [1, 0], property: "font-size", value: "20px"),
      to: source
    )

    #expect(edited.contains("font-size: 14px;"))
    #expect(edited.contains("font-size: 20px;"))
    #expect(!edited.contains("font-size: 18px;"))
  }

  @Test("Duplicate declarations edit the last occurrence")
  func duplicateDeclarationsEditLast() throws {
    let source = ".a { color: red; color: blue; }"

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "color", value: "green"),
      to: source
    )

    #expect(edited == ".a { color: red; color: green; }")
  }

  @Test("Removing a declaration also removes its now-empty line")
  func removeDeclarationCleansLine() throws {
    let source = """
    .cta {
      color: red;
      padding: 12px;
    }
    """

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "padding", value: nil),
      to: source
    )

    #expect(edited == """
    .cta {
      color: red;
    }
    """)
  }

  @Test("Removing a missing declaration is a no-op")
  func removeMissingDeclarationIsNoOp() throws {
    let source = ".a { color: red; }"

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "padding", value: nil),
      to: source
    )

    #expect(edited == source)
  }

  @Test("Editing an unknown rule index path throws ruleNotFound")
  func unknownRuleIndexPathThrows() {
    #expect(throws: CSSSourceEditorError.ruleNotFound([3])) {
      _ = try CSSSourceEditor().applyingDeclarationEdit(
        CSSDeclarationEdit(ruleIndexPath: [3], property: "color", value: "red"),
        to: ".a { color: red; }"
      )
    }
  }

  @Test("Multibyte content before the rule does not corrupt splice offsets")
  func multibyteContentIsHandled() throws {
    let source = """
    /* café — emoji 🎨 comment */
    .título { color: red; content: "日本語"; }
    """

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "color", value: "blue"),
      to: source
    )

    #expect(edited.contains("color: blue;"))
    #expect(edited.contains("content: \"日本語\";"))
    #expect(edited.contains("café — emoji 🎨"))
  }

  @Test("CRLF line endings survive an edit")
  func crlfSurvivesEdit() throws {
    let source = ".a {\r\n  color: red;\r\n}\r\n"

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "color", value: "blue"),
      to: source
    )

    #expect(edited == ".a {\r\n  color: blue;\r\n}\r\n")
  }

  @Test("Minified CSS edits stay scoped to the target declaration")
  func minifiedCSSEdits() throws {
    let source = ".a{color:red;padding:4px}.b{color:blue}"

    let edited = try editor.applyingDeclarationEdit(
      CSSDeclarationEdit(ruleIndexPath: [0], property: "padding", value: "8px"),
      to: source
    )

    #expect(edited == ".a{color:red;padding:8px}.b{color:blue}")
  }
}
