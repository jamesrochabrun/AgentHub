//
//  CSSDeclarationEditPlannerTests.swift
//  AgentHubTests
//

import Foundation
import Testing

@testable import AgentHubCore

@Suite("CSSDeclarationEditPlanner")
struct CSSDeclarationEditPlannerTests {

  /// Environment with distinct root/element/parent font sizes so tests can
  /// tell which basis a unit conversion actually used.
  private let environment = WebPreviewPageEnvironment(
    viewportWidth: 1280,
    viewportHeight: 800,
    rootFontSize: 16,
    elementFontSize: 18,
    parentFontSize: 20
  )

  private func plan(
    css: String,
    siblings: [String] = [],
    ruleIndexPath: [Int] = [0],
    property: String,
    desired: String?
  ) throws -> CSSDeclarationEditPlan {
    let editor = CSSSourceEditor()
    let document = try editor.parse(css)
    let siblingDocuments = try siblings.map { try editor.parse($0) }
    return CSSDeclarationEditPlanner().plan(
      CSSDeclarationEdit(ruleIndexPath: ruleIndexPath, property: property, value: desired),
      in: document,
      siblings: siblingDocuments,
      environment: environment
    )
  }

  // MARK: - Unit preservation

  @Test("A rem declaration converts a desired px value back into rem")
  func remUnitPreserved() throws {
    let plan = try plan(
      css: ".hero { font-size: 1.05rem; }",
      property: "font-size",
      desired: "24px"
    )

    #expect(plan.strategy == .unitConverted)
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [0], property: "font-size", value: "1.5rem"))
  }

  @Test("em on font-size converts against the parent font size")
  func emFontSizeUsesParentFontSize() throws {
    let plan = try plan(
      css: ".hero { font-size: 1em; }",
      property: "font-size",
      desired: "30px"
    )

    // parentFontSize is 20, so 30px is 1.5em (elementFontSize 18 would give 1.6667em).
    #expect(plan.strategy == .unitConverted)
    #expect(plan.edit?.value == "1.5em")
  }

  @Test("em on letter-spacing converts against the element font size")
  func emLetterSpacingUsesElementFontSize() throws {
    let plan = try plan(
      css: ".hero { letter-spacing: 0.5em; }",
      property: "letter-spacing",
      desired: "27px"
    )

    // elementFontSize is 18, so 27px is 1.5em (parentFontSize 20 would give 1.35em).
    #expect(plan.strategy == .unitConverted)
    #expect(plan.edit?.value == "1.5em")
  }

  @Test("Unitless line-height stays unitless")
  func unitlessLineHeightPreserved() throws {
    let plan = try plan(
      css: ".hero { line-height: 1.45; }",
      property: "line-height",
      desired: "27px"
    )

    // elementFontSize is 18, so 27px is a 1.5 multiple.
    #expect(plan.strategy == .unitConverted)
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [0], property: "line-height", value: "1.5"))
  }

  @Test("A desired px equal to the unitless line-height's evaluation is a no-op")
  func unitlessLineHeightNoChange() throws {
    let plan = try plan(
      css: ".hero { line-height: 1.45; }",
      property: "line-height",
      desired: "26.1px"
    )

    // 1.45 * 18 = 26.1px, so nothing needs to change.
    #expect(plan.strategy == .noChange)
    #expect(plan.edit == nil)
  }

  @Test("A desired length equal to the declared length is a no-op")
  func equalLengthIsNoChange() throws {
    let plan = try plan(
      css: ".hero { font-size: 24px; }",
      property: "font-size",
      desired: "24px"
    )

    #expect(plan.strategy == .noChange)
    #expect(plan.edit == nil)
  }

  // MARK: - Responsive expressions

  @Test("clamp() adjusts only the preferred term when the desired value stays in bounds")
  func clampAdjustsPreferred() throws {
    let plan = try plan(
      css: ".hero { font-size: clamp(17px, 2.2vw, 22px); }",
      property: "font-size",
      desired: "19.2px"
    )

    // 19.2px at a 1280px viewport is 1.5vw.
    #expect(plan.strategy == .responsiveAdjusted)
    #expect(plan.edit?.value == "clamp(17px, 1.5vw, 22px)")
  }

  @Test("clamp() widens the max bound when the desired value exceeds it")
  func clampWidensMax() throws {
    let plan = try plan(
      css: ".hero { font-size: clamp(17px, 2.2vw, 22px); }",
      property: "font-size",
      desired: "30px"
    )

    // 30 / 1280 * 100 = 2.34375, rounded to 3 decimals for vw.
    #expect(plan.strategy == .responsiveAdjusted)
    #expect(plan.edit?.value == "clamp(17px, 2.344vw, 30px)")
  }

  @Test("clamp() widens the min bound when the desired value undershoots it")
  func clampWidensMin() throws {
    let plan = try plan(
      css: ".hero { font-size: clamp(17px, 2.2vw, 22px); }",
      property: "font-size",
      desired: "10px"
    )

    // 10 / 1280 * 100 = 0.78125, rounded to 3 decimals for vw.
    #expect(plan.strategy == .responsiveAdjusted)
    #expect(plan.edit?.value == "clamp(10px, 0.781vw, 22px)")
  }

  @Test("min() adjusts the winning argument while it stays the winner")
  func minAdjustsWinner() throws {
    let plan = try plan(
      css: ".panel { width: min(90vw, 640px); }",
      property: "width",
      desired: "600px"
    )

    // At 1280px, 90vw = 1152px, so 640px wins and can drop to 600px.
    #expect(plan.strategy == .responsiveAdjusted)
    #expect(plan.edit?.value == "min(90vw, 600px)")
  }

  @Test("min() passes through when the desired value would dethrone the winner")
  func minPassthroughWhenWinnerChanges() throws {
    let edit = CSSDeclarationEdit(ruleIndexPath: [0], property: "width", value: "1200px")
    let document = try CSSSourceEditor().parse(".panel { width: min(90vw, 640px); }")
    let plan = CSSDeclarationEditPlanner().plan(edit, in: document, environment: environment)

    // 1200px is above 90vw = 1152px, so adjusting 640px cannot express it.
    #expect(plan.strategy == .passthrough)
    #expect(plan.edit == edit)
  }

  // MARK: - Design tokens

  @Test("A var() declaration reattaches to the token that resolves to the desired value")
  func varReattachesToMatchingToken() throws {
    let css = ":root { --brand: #445566; --accent: #112233; } .cta { color: var(--accent); }"
    let plan = try plan(
      css: css,
      ruleIndexPath: [1],
      property: "color",
      desired: "#445566"
    )

    #expect(plan.strategy == .tokenReattached("--brand"))
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [1], property: "color", value: "var(--brand)"))
  }

  @Test("A var() declaration whose token already resolves to the desired value is a no-op")
  func varNoChangeWhenTokenResolvesToDesired() throws {
    let css = ":root { --brand: #445566; --accent: #112233; } .cta { color: var(--accent); }"
    let plan = try plan(
      css: css,
      ruleIndexPath: [1],
      property: "color",
      desired: "#112233"
    )

    #expect(plan.strategy == .noChange)
    #expect(plan.edit == nil)
  }

  @Test("A single-consumer token edit retargets the token's own definition")
  func singleUseTokenDefinitionRewritten() throws {
    let css = ":root { --hero-size: 60px; } h1 { font-size: var(--hero-size); }"
    let plan = try plan(
      css: css,
      ruleIndexPath: [1],
      property: "font-size",
      desired: "48px"
    )

    #expect(plan.strategy == .tokenDefinitionRewritten("--hero-size"))
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [0], property: "--hero-size", value: "48px"))
  }

  @Test("A multi-consumer token detaches into a literal that keeps the token's notation")
  func multiUseTokenDetached() throws {
    let css = ":root { --fg: rgb(94, 94, 94); } .a { color: var(--fg); } .b { color: var(--fg); }"
    let plan = try plan(
      css: css,
      ruleIndexPath: [1],
      property: "color",
      desired: "#224466"
    )

    #expect(plan.strategy == .tokenDetached("--fg"))
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [1], property: "color", value: "rgb(34, 68, 102)"))
  }

  @Test("A mixed-case token keeps its exact spelling through a definition rewrite")
  func mixedCaseTokenDefinitionRewritten() throws {
    let css = ":root { --heroSize: 60px; } h1 { font-size: var(--heroSize); }"
    let plan = try plan(
      css: css,
      ruleIndexPath: [1],
      property: "font-size",
      desired: "48px"
    )

    #expect(plan.strategy == .tokenDefinitionRewritten("--heroSize"))
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [0], property: "--heroSize", value: "48px"))
  }

  @Test("Tokens that differ only by case stay distinct")
  func caseSensitiveTokensStayDistinct() throws {
    // --FG and --fg are different custom properties; editing the --fg
    // consumer must not treat --FG's usage as a second consumer.
    let css = ":root { --fg: #101010; --FG: #efefef; } .a { color: var(--fg); } .b { color: var(--FG); }"
    let plan = try plan(
      css: css,
      ruleIndexPath: [1],
      property: "color",
      desired: "#224466"
    )

    #expect(plan.strategy == .tokenDefinitionRewritten("--fg"))
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [0], property: "--fg", value: "#224466"))
  }

  // MARK: - Cross-file tokens

  @Test("A token consumed by a sibling stylesheet is not rewritten at its definition")
  func siblingUsageBlocksDefinitionRewrite() throws {
    let css = ":root { --hero-size: 60px; } h1 { font-size: var(--hero-size); }"
    let sibling = ".banner { font-size: var(--hero-size); }"
    let plan = try plan(
      css: css,
      siblings: [sibling],
      ruleIndexPath: [1],
      property: "font-size",
      desired: "48px"
    )

    // Rewriting :root's --hero-size would restyle .banner too, so the edit
    // detaches this one consumer instead (keeping the declared unit).
    #expect(plan.strategy == .tokenDetached("--hero-size"))
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [1], property: "font-size", value: "48px"))
  }

  @Test("Reattachment can target a token defined in a sibling stylesheet")
  func reattachesToSiblingDefinedToken() throws {
    let css = ":root { --accent: #112233; } .cta { color: var(--accent); } .other { color: var(--accent); }"
    let sibling = ":root { --brand: #445566; }"
    let plan = try plan(
      css: css,
      siblings: [sibling],
      ruleIndexPath: [1],
      property: "color",
      desired: "#445566"
    )

    #expect(plan.strategy == .tokenReattached("--brand"))
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [1], property: "color", value: "var(--brand)"))
  }

  @Test("A token redefined by a sibling stylesheet detaches with the desired literal")
  func siblingRedefinitionForcesLiteralDetach() throws {
    let css = ":root { --fg: #101010; } .a { color: var(--fg); }"
    let sibling = ":root { --fg: #efefef; }"
    let plan = try plan(
      css: css,
      siblings: [sibling],
      ruleIndexPath: [1],
      property: "color",
      desired: "#224466"
    )

    // Two definitions make the token's resolution ambiguous: no rewrite, no
    // notation to mirror — the desired literal lands on the consumer.
    #expect(plan.strategy == .tokenDetached("--fg"))
    #expect(plan.edit == CSSDeclarationEdit(ruleIndexPath: [1], property: "color", value: "#224466"))
  }

  // MARK: - Colors

  @Test("An rgb() declaration keeps rgb() notation for a desired hex value")
  func rgbFormatPreserved() throws {
    let plan = try plan(
      css: ".a { color: rgb(94, 94, 94); }",
      property: "color",
      desired: "#224466"
    )

    #expect(plan.strategy == .colorFormatPreserved)
    #expect(plan.edit?.value == "rgb(34, 68, 102)")
  }

  @Test("An hsl() declaration keeps hsl() notation for a desired hex value")
  func hslFormatPreserved() throws {
    let plan = try plan(
      css: ".a { color: hsl(220, 50%, 40%); }",
      property: "color",
      desired: "#336699"
    )

    // #336699 is hsl(210, 50%, 40%).
    #expect(plan.strategy == .colorFormatPreserved)
    #expect(plan.edit?.value == "hsl(210, 50%, 40%)")
  }

  @Test("A keyword declaration carries no notation, so the desired text passes through")
  func keywordDeclaredPassesDesiredText() throws {
    let plan = try plan(
      css: ".a { color: red; }",
      property: "color",
      desired: "blue"
    )

    #expect(plan.strategy == .colorFormatPreserved)
    #expect(plan.edit?.value == "blue")
  }

  @Test("An uppercase hex declaration keeps its casing")
  func uppercaseHexPreserved() throws {
    let plan = try plan(
      css: ".a { color: #ABCDEF; }",
      property: "color",
      desired: "#123abc"
    )

    #expect(plan.strategy == .colorFormatPreserved)
    #expect(plan.edit?.value == "#123ABC")
  }

  @Test("Equal colors across notations are a no-op")
  func equalColorsAcrossNotationsNoChange() throws {
    let plan = try plan(
      css: ".a { color: #5e5e5e; }",
      property: "color",
      desired: "rgb(94, 94, 94)"
    )

    #expect(plan.strategy == .noChange)
    #expect(plan.edit == nil)
  }

  @Test("An rgba() declaration keeps rgba() notation including the desired alpha")
  func alphaPreservedInRGBA() throws {
    let plan = try plan(
      css: ".a { background-color: rgba(0, 0, 0, 0.5); }",
      property: "background-color",
      desired: "#22446680"
    )

    // 0x80 / 255 rounds to 0.502.
    #expect(plan.strategy == .colorFormatPreserved)
    #expect(plan.edit?.value == "rgba(34, 68, 102, 0.502)")
  }

  // MARK: - Passthrough

  @Test("A gradient declaration passes the desired literal through unchanged")
  func gradientPassthrough() throws {
    let edit = CSSDeclarationEdit(ruleIndexPath: [0], property: "background", value: "#123456")
    let document = try CSSSourceEditor().parse(
      ".a { background: linear-gradient(180deg, #ffffff, #000000); }"
    )
    let plan = CSSDeclarationEditPlanner().plan(edit, in: document, environment: environment)

    #expect(plan.strategy == .passthrough)
    #expect(plan.edit == edit)
  }

  @Test("Editing a property the rule does not declare passes through")
  func missingDeclarationPassthrough() throws {
    let edit = CSSDeclarationEdit(ruleIndexPath: [0], property: "color", value: "#ffffff")
    let document = try CSSSourceEditor().parse(".hero { font-size: 1.05rem; }")
    let plan = CSSDeclarationEditPlanner().plan(edit, in: document, environment: environment)

    #expect(plan.strategy == .passthrough)
    #expect(plan.edit == edit)
  }

  @Test("A clamp() containing var() passes through")
  func clampWithVarPassthrough() throws {
    let edit = CSSDeclarationEdit(ruleIndexPath: [0], property: "font-size", value: "20px")
    let document = try CSSSourceEditor().parse(
      ".hero { font-size: clamp(var(--min), 2vw, 30px); }"
    )
    let plan = CSSDeclarationEditPlanner().plan(edit, in: document, environment: environment)

    #expect(plan.strategy == .passthrough)
    #expect(plan.edit == edit)
  }

  @Test("A removal (nil value) passes through untouched")
  func removalPassthrough() throws {
    let edit = CSSDeclarationEdit(ruleIndexPath: [0], property: "font-size", value: nil)
    let document = try CSSSourceEditor().parse(".hero { font-size: 1.05rem; }")
    let plan = CSSDeclarationEditPlanner().plan(edit, in: document, environment: environment)

    #expect(plan.strategy == .passthrough)
    #expect(plan.edit == edit)
  }
}
