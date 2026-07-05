//
//  CSSDeclarationEditPlanner.swift
//  AgentHub
//
//  Deterministically rewrites a desired literal value so a Tier-1 direct
//  write preserves the idioms already used by the declaration it edits:
//  design tokens stay tokens, clamp()/min()/max() keep their responsive
//  structure, lengths keep their declared unit, and colors keep their
//  declared notation. Everything here is pure parsing and arithmetic — no
//  heuristics, no agent. When a value cannot be preserved faithfully the
//  planner passes the desired literal through unchanged, which is exactly
//  the pre-planner behavior.
//

import Foundation

// MARK: - Plan

struct CSSDeclarationEditPlan: Equatable, Sendable {
  enum Strategy: Equatable, Sendable {
    /// The declaration already has the desired value; skip the write.
    case noChange
    /// Desired literal written as-is (no idiom to preserve, or one the
    /// planner does not model).
    case passthrough
    /// Length converted into the unit the declaration already uses.
    case unitConverted
    /// Color reformatted into the notation the declaration already uses.
    case colorFormatPreserved
    /// clamp()/min()/max() adjusted component-wise instead of flattened.
    case responsiveAdjusted
    /// Value replaced with a `var()` reference to an existing token whose
    /// resolved value equals the desired value.
    case tokenReattached(String)
    /// The edit was retargeted to the token's own definition because this
    /// declaration is its only consumer.
    case tokenDefinitionRewritten(String)
    /// A `var()` reference replaced by a literal (multi-consumer token, so
    /// element-scoped intent cannot be expressed through the token).
    case tokenDetached(String)
  }

  /// The finalized edit, possibly retargeted to another rule in the same
  /// stylesheet. Nil means the write should be skipped entirely.
  let edit: CSSDeclarationEdit?
  let strategy: Strategy
  /// Set when the plan detached a `var()` usage into a literal: everything
  /// a caller needs to later offer "update the token everywhere instead".
  let tokenDetachment: CSSTokenDetachment?

  init(
    edit: CSSDeclarationEdit?,
    strategy: Strategy,
    tokenDetachment: CSSTokenDetachment? = nil
  ) {
    self.edit = edit
    self.strategy = strategy
    self.tokenDetachment = tokenDetachment
  }
}

/// Describes a `var()` usage the planner flattened into a literal because
/// the token has other consumers. When `definitionRuleIndexPath` is set the
/// token's single definition lives in the edited document, so the edit can
/// be deterministically promoted to a token-wide update: restore the usage
/// to `var(token)` and rewrite the definition.
struct CSSTokenDetachment: Equatable, Sendable {
  let token: String
  /// `var(token)` usages across the edited document and its siblings.
  let projectUsageCount: Int
  /// Rule index path of the token's definition within the edited document;
  /// nil when the definition is elsewhere (promotion not offered).
  let definitionRuleIndexPath: [Int]?
  /// The literal the plan wrote in place of the `var()` reference.
  let appliedLiteral: String

  init(
    token: String,
    projectUsageCount: Int,
    definitionRuleIndexPath: [Int]?,
    appliedLiteral: String
  ) {
    self.token = token
    self.projectUsageCount = projectUsageCount
    self.definitionRuleIndexPath = definitionRuleIndexPath
    self.appliedLiteral = appliedLiteral
  }
}

protocol CSSDeclarationEditPlanning: Sendable {
  /// Plans an edit against the document it targets. `siblings` are the other
  /// stylesheets of the same page/project: they never receive edits, but
  /// their `--token` definitions and `var()` usages participate in token
  /// resolution so a definition rewrite can't silently restyle consumers in
  /// other files.
  func plan(
    _ edit: CSSDeclarationEdit,
    in document: CSSSourceDocument,
    siblings: [CSSSourceDocument],
    environment: WebPreviewPageEnvironment
  ) -> CSSDeclarationEditPlan
}

extension CSSDeclarationEditPlanning {
  func plan(
    _ edit: CSSDeclarationEdit,
    in document: CSSSourceDocument,
    environment: WebPreviewPageEnvironment
  ) -> CSSDeclarationEditPlan {
    plan(edit, in: document, siblings: [], environment: environment)
  }
}

// MARK: - Planner

struct CSSDeclarationEditPlanner: CSSDeclarationEditPlanning {

  init() {}

  func plan(
    _ edit: CSSDeclarationEdit,
    in document: CSSSourceDocument,
    siblings: [CSSSourceDocument],
    environment: WebPreviewPageEnvironment
  ) -> CSSDeclarationEditPlan {
    guard let desired = edit.value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !desired.isEmpty else {
      // Removals pass through untouched.
      return CSSDeclarationEditPlan(edit: edit, strategy: .passthrough)
    }

    guard let rule = document.rule(at: edit.ruleIndexPath),
          let declaration = rule.declarations.last(where: {
            $0.name == CSSSourceEditor.canonicalPropertyName(edit.property)
          }) else {
      // Inserting a brand-new declaration: nothing declared to preserve.
      return CSSDeclarationEditPlan(edit: edit, strategy: .passthrough)
    }

    let declared = declaration.valueText.trimmingCharacters(in: .whitespacesAndNewlines)

    if valuesAreEquivalent(declared, desired, property: edit.property, environment: environment) {
      return CSSDeclarationEditPlan(edit: nil, strategy: .noChange)
    }

    // 1. Pure design-token reference: var(--x) or var(--x, fallback).
    if let tokenName = Self.pureVarReference(declared) {
      return planTokenEdit(
        edit,
        tokenName: tokenName,
        desired: desired,
        in: document,
        siblings: siblings,
        environment: environment
      )
    }

    // 2. Responsive expression: clamp()/min()/max() of single-term lengths.
    if let adjusted = Self.adjustedResponsiveExpression(
      declared: declared,
      desired: desired,
      property: edit.property,
      environment: environment
    ) {
      return CSSDeclarationEditPlan(
        edit: CSSDeclarationEdit(ruleIndexPath: edit.ruleIndexPath, property: edit.property, value: adjusted),
        strategy: .responsiveAdjusted
      )
    }

    // 3. Color notation preservation.
    if let declaredColor = CSSColorValue.parse(declared),
       let desiredColor = CSSColorValue.parse(desired) {
      if declaredColor == desiredColor {
        return CSSDeclarationEditPlan(edit: nil, strategy: .noChange)
      }
      let formatted = Self.colorRewrite(declared: declared, desired: desired, desiredColor: desiredColor)
      return CSSDeclarationEditPlan(
        edit: CSSDeclarationEdit(ruleIndexPath: edit.ruleIndexPath, property: edit.property, value: formatted),
        strategy: .colorFormatPreserved
      )
    }

    // 4. Single length literal: preserve the declared unit.
    if let converted = Self.convertedLength(
      declared: declared,
      desired: desired,
      property: edit.property,
      environment: environment
    ) {
      if converted == declared {
        return CSSDeclarationEditPlan(edit: nil, strategy: .noChange)
      }
      return CSSDeclarationEditPlan(
        edit: CSSDeclarationEdit(ruleIndexPath: edit.ruleIndexPath, property: edit.property, value: converted),
        strategy: .unitConverted
      )
    }

    return CSSDeclarationEditPlan(edit: edit, strategy: .passthrough)
  }

  // MARK: - Token planning

  private func planTokenEdit(
    _ edit: CSSDeclarationEdit,
    tokenName: String,
    desired: String,
    in document: CSSSourceDocument,
    siblings: [CSSSourceDocument],
    environment: WebPreviewPageEnvironment
  ) -> CSSDeclarationEditPlan {
    let table = CSSCustomPropertyTable(document: document, siblings: siblings)

    // No-op: the desired value is what the token already resolves to.
    if let resolved = table.resolvedLiteral(for: tokenName),
       valuesAreEquivalent(resolved, desired, property: edit.property, environment: environment) {
      return CSSDeclarationEditPlan(edit: nil, strategy: .noChange)
    }

    // Reattach: exactly one other token already resolves to the desired
    // value — reference it instead of flattening to a literal.
    let matches = table.tokens { candidate in
      self.valuesAreEquivalent(candidate, desired, property: edit.property, environment: environment)
    }
    if matches.count == 1, let match = matches.first {
      return CSSDeclarationEditPlan(
        edit: CSSDeclarationEdit(
          ruleIndexPath: edit.ruleIndexPath,
          property: edit.property,
          value: "var(\(match))"
        ),
        strategy: .tokenReattached(match)
      )
    }

    // Single-consumer token: this declaration is the token's only usage and
    // it has exactly one plain-literal definition — update the definition so
    // the indirection survives.
    if table.usageCount(of: tokenName) == 1,
       let definition = table.singleLiteralDefinition(of: tokenName, visibleFrom: edit.ruleIndexPath) {
      let rewritten = Self.preservingLiteralRewrite(
        declared: definition.valueText,
        desired: desired,
        property: edit.property,
        environment: environment
      )
      return CSSDeclarationEditPlan(
        edit: CSSDeclarationEdit(
          ruleIndexPath: definition.ruleIndexPath,
          property: tokenName,
          value: rewritten
        ),
        strategy: .tokenDefinitionRewritten(tokenName)
      )
    }

    // Detach: the token has other consumers, so an element-scoped edit must
    // become a literal here. Keep the token's notation where possible, and
    // record enough context to offer a token-wide update afterwards.
    let literal: String
    if let resolved = table.resolvedLiteral(for: tokenName) {
      literal = Self.preservingLiteralRewrite(
        declared: resolved,
        desired: desired,
        property: edit.property,
        environment: environment
      )
    } else {
      literal = desired
    }
    return CSSDeclarationEditPlan(
      edit: CSSDeclarationEdit(ruleIndexPath: edit.ruleIndexPath, property: edit.property, value: literal),
      strategy: .tokenDetached(tokenName),
      tokenDetachment: CSSTokenDetachment(
        token: tokenName,
        projectUsageCount: table.usageCount(of: tokenName),
        definitionRuleIndexPath: table.promotableDefinition(of: tokenName)?.ruleIndexPath,
        appliedLiteral: literal
      )
    )
  }

  /// Keyword-declared colors carry no notation to preserve, so the desired
  /// text passes through as-is; every other notation is mirrored.
  static func colorRewrite(declared: String, desired: String, desiredColor: CSSColorValue) -> String {
    let keyword = declared.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if CSSColorValue.keywords[keyword] != nil {
      return desired
    }
    return desiredColor.formatted(like: declared)
  }

  /// Rewrites `desired` into the same notation as an existing literal
  /// (color format or length unit); falls back to `desired` unchanged.
  static func preservingLiteralRewrite(
    declared: String,
    desired: String,
    property: String,
    environment: WebPreviewPageEnvironment
  ) -> String {
    if CSSColorValue.parse(declared) != nil, let desiredColor = CSSColorValue.parse(desired) {
      return colorRewrite(declared: declared, desired: desired, desiredColor: desiredColor)
    }
    if let converted = convertedLength(
      declared: declared,
      desired: desired,
      property: property,
      environment: environment
    ) {
      return converted
    }
    return desired
  }

  // MARK: - Equivalence

  private func valuesAreEquivalent(
    _ lhs: String,
    _ rhs: String,
    property: String,
    environment: WebPreviewPageEnvironment
  ) -> Bool {
    if let lhsColor = CSSColorValue.parse(lhs), let rhsColor = CSSColorValue.parse(rhs) {
      return lhsColor == rhsColor
    }
    if let lhsLength = CSSLengthTerm.parse(lhs),
       let rhsLength = CSSLengthTerm.parse(rhs),
       let lhsPx = lhsLength.pixels(property: property, environment: environment),
       let rhsPx = rhsLength.pixels(property: property, environment: environment) {
      return abs(lhsPx - rhsPx) < 0.05
    }
    return lhs.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
      == rhs.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  // MARK: - var() detection

  /// Returns the token name when the whole value is a single `var()`
  /// reference (with optional fallback). Token names keep their original
  /// case — custom properties are case-sensitive and the parser preserves
  /// their spelling.
  static func pureVarReference(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("var("), trimmed.hasSuffix(")") else { return nil }

    let inner = String(trimmed.dropFirst(4).dropLast(1))
    // The reference must close at the very end (no trailing operators).
    guard Self.topLevelSplit(inner).count <= 2 else { return nil }
    let name = Self.topLevelSplit(inner).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard name.hasPrefix("--"), name.count > 2 else { return nil }
    guard name.dropFirst(2).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
      return nil
    }
    // Reject `var(--a) solid red` style compounds: the suffix check above
    // only guarantees the string ends with ')'; ensure the closing paren
    // belongs to this var().
    var depth = 0
    for (offset, character) in trimmed.enumerated() {
      if character == "(" { depth += 1 }
      if character == ")" {
        depth -= 1
        if depth == 0, offset < trimmed.count - 1 { return nil }
      }
    }
    return name
  }

  // MARK: - Responsive expressions

  /// Rewrites `clamp()/min()/max()` component-wise so the expression yields
  /// the desired value at the current environment while keeping its
  /// structure. Returns nil when the expression is not one the planner can
  /// adjust faithfully.
  static func adjustedResponsiveExpression(
    declared: String,
    desired: String,
    property: String,
    environment: WebPreviewPageEnvironment
  ) -> String? {
    let trimmed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()

    let function: String
    if lowered.hasPrefix("clamp(") {
      function = "clamp"
    } else if lowered.hasPrefix("min(") {
      function = "min"
    } else if lowered.hasPrefix("max(") {
      function = "max"
    } else {
      return nil
    }
    guard trimmed.hasSuffix(")") else { return nil }

    let innerStart = trimmed.index(trimmed.startIndex, offsetBy: function.count + 1)
    let innerEnd = trimmed.index(before: trimmed.endIndex)
    let inner = String(trimmed[innerStart..<innerEnd])

    let arguments = topLevelSplit(inner)
    guard !arguments.isEmpty else { return nil }

    var terms: [CSSLengthTerm] = []
    var evaluations: [Double] = []
    for argument in arguments {
      guard let term = CSSLengthTerm.parse(argument.trimmingCharacters(in: .whitespacesAndNewlines)),
            let pixels = term.pixels(property: property, environment: environment) else {
        return nil
      }
      terms.append(term)
      evaluations.append(pixels)
    }

    guard let desiredTerm = CSSLengthTerm.parse(desired),
          let desiredPx = desiredTerm.pixels(property: property, environment: environment) else {
      return nil
    }

    var replacements: [Int: String] = [:]

    switch function {
    case "clamp":
      guard terms.count == 3 else { return nil }
      // The preferred expression tracks the slider; bounds widen only when
      // the desired value crosses them, so the responsive curve survives.
      replacements[1] = terms[1].formatted(fromPixels: desiredPx, property: property, environment: environment)
      if desiredPx < evaluations[0] {
        replacements[0] = terms[0].formatted(fromPixels: desiredPx, property: property, environment: environment)
      }
      if desiredPx > evaluations[2] {
        replacements[2] = terms[2].formatted(fromPixels: desiredPx, property: property, environment: environment)
      }

    case "min":
      guard terms.count >= 2, let winnerValue = evaluations.min(),
            let winner = evaluations.firstIndex(of: winnerValue) else { return nil }
      // Adjusting the winning argument only works while it stays the winner.
      guard evaluations.enumerated().allSatisfy({ $0.offset == winner || desiredPx <= $0.element + 0.05 }) else {
        return nil
      }
      replacements[winner] = terms[winner].formatted(fromPixels: desiredPx, property: property, environment: environment)

    case "max":
      guard terms.count >= 2, let winnerValue = evaluations.max(),
            let winner = evaluations.firstIndex(of: winnerValue) else { return nil }
      guard evaluations.enumerated().allSatisfy({ $0.offset == winner || desiredPx >= $0.element - 0.05 }) else {
        return nil
      }
      replacements[winner] = terms[winner].formatted(fromPixels: desiredPx, property: property, environment: environment)

    default:
      return nil
    }

    guard replacements.values.allSatisfy({ !$0.isEmpty }) else { return nil }

    let rebuiltArguments = arguments.enumerated().map { index, original -> String in
      guard let replacement = replacements[index] else { return original }
      // Preserve the original argument's surrounding whitespace.
      let leading = original.prefix(while: \.isWhitespace)
      let trailing = String(original.reversed().prefix(while: \.isWhitespace).reversed())
      return leading + replacement + trailing
    }

    return "\(function)(\(rebuiltArguments.joined(separator: ",")))"
  }

  // MARK: - Lengths

  /// Converts a desired length into the unit of the declared literal.
  /// Returns nil when either side is not a single supported length term.
  static func convertedLength(
    declared: String,
    desired: String,
    property: String,
    environment: WebPreviewPageEnvironment
  ) -> String? {
    guard let declaredTerm = CSSLengthTerm.parse(declared),
          declaredTerm.pixels(property: property, environment: environment) != nil,
          let desiredTerm = CSSLengthTerm.parse(desired),
          let desiredPx = desiredTerm.pixels(property: property, environment: environment) else {
      return nil
    }
    let formatted = declaredTerm.formatted(fromPixels: desiredPx, property: property, environment: environment)
    return formatted.isEmpty ? nil : formatted
  }

  // MARK: - Shared parsing helpers

  /// Splits on top-level commas (ignoring commas nested in parentheses,
  /// brackets, or strings).
  static func topLevelSplit(_ text: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    var stringDelimiter: Character?

    for character in text {
      if let delimiter = stringDelimiter {
        current.append(character)
        if character == delimiter { stringDelimiter = nil }
        continue
      }
      switch character {
      case "\"", "'":
        stringDelimiter = character
        current.append(character)
      case "(", "[":
        depth += 1
        current.append(character)
      case ")", "]":
        depth -= 1
        current.append(character)
      case "," where depth == 0:
        parts.append(current)
        current = ""
      default:
        current.append(character)
      }
    }
    parts.append(current)
    return parts
  }
}

// MARK: - Length terms

/// A single numeric CSS length term (`17px`, `2.2vw`, `1.05rem`, `1.45`).
struct CSSLengthTerm: Equatable {
  let value: Double
  /// Lowercased unit; empty for unitless numbers.
  let unit: String

  static let supportedUnits: Set<String> = ["px", "rem", "em", "vw", "vh", "vmin", "vmax", ""]

  static func parse(_ text: String) -> CSSLengthTerm? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return nil }

    var numberEnd = trimmed.startIndex
    var seenDigit = false
    var seenDot = false
    var index = trimmed.startIndex
    while index < trimmed.endIndex {
      let character = trimmed[index]
      if character == "+" || character == "-" {
        guard index == trimmed.startIndex else { break }
      } else if character == "." {
        guard !seenDot else { break }
        seenDot = true
      } else if character.isNumber {
        seenDigit = true
      } else {
        break
      }
      index = trimmed.index(after: index)
      numberEnd = index
    }

    guard seenDigit, let value = Double(trimmed[trimmed.startIndex..<numberEnd]) else { return nil }
    let unit = String(trimmed[numberEnd...])
    guard supportedUnits.contains(unit) else { return nil }
    return CSSLengthTerm(value: value, unit: unit)
  }

  /// Evaluates the term to CSS pixels. Unitless terms are only meaningful
  /// for line-height (a multiple of the element's font size); elsewhere a
  /// bare number is treated as pixels, matching how editor toolbars emit
  /// values.
  func pixels(property: String, environment: WebPreviewPageEnvironment) -> Double? {
    switch unit {
    case "px":
      return value
    case "rem":
      return value * environment.rootFontSize
    case "em":
      let basis = property.lowercased() == "font-size"
        ? environment.parentFontSize
        : environment.elementFontSize
      return value * basis
    case "vw":
      return value * environment.viewportWidth / 100
    case "vh":
      return value * environment.viewportHeight / 100
    case "vmin":
      return value * min(environment.viewportWidth, environment.viewportHeight) / 100
    case "vmax":
      return value * max(environment.viewportWidth, environment.viewportHeight) / 100
    case "":
      if property.lowercased() == "line-height" {
        return value * environment.elementFontSize
      }
      return value
    default:
      return nil
    }
  }

  /// Formats a pixel amount in this term's unit.
  func formatted(fromPixels pixels: Double, property: String, environment: WebPreviewPageEnvironment) -> String {
    func output(_ value: Double, decimals: Int) -> String {
      let rounded = (value * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
      guard rounded.isFinite else { return "" }
      var text = String(format: "%.\(decimals)f", rounded)
      while text.contains("."), text.hasSuffix("0") { text.removeLast() }
      if text.hasSuffix(".") { text.removeLast() }
      if text == "-0" { text = "0" }
      return text
    }

    switch unit {
    case "px":
      return output(pixels, decimals: 2) + "px"
    case "rem":
      guard environment.rootFontSize > 0 else { return "" }
      return output(pixels / environment.rootFontSize, decimals: 4) + "rem"
    case "em":
      let basis = property.lowercased() == "font-size"
        ? environment.parentFontSize
        : environment.elementFontSize
      guard basis > 0 else { return "" }
      return output(pixels / basis, decimals: 4) + "em"
    case "vw":
      guard environment.viewportWidth > 0 else { return "" }
      return output(pixels / environment.viewportWidth * 100, decimals: 3) + "vw"
    case "vh":
      guard environment.viewportHeight > 0 else { return "" }
      return output(pixels / environment.viewportHeight * 100, decimals: 3) + "vh"
    case "vmin":
      let basis = min(environment.viewportWidth, environment.viewportHeight)
      guard basis > 0 else { return "" }
      return output(pixels / basis * 100, decimals: 3) + "vmin"
    case "vmax":
      let basis = max(environment.viewportWidth, environment.viewportHeight)
      guard basis > 0 else { return "" }
      return output(pixels / basis * 100, decimals: 3) + "vmax"
    case "":
      if property.lowercased() == "line-height" {
        guard environment.elementFontSize > 0 else { return "" }
        return output(pixels / environment.elementFontSize, decimals: 4)
      }
      return output(pixels, decimals: 2)
    default:
      return ""
    }
  }
}

// MARK: - Custom property table

/// Indexes every `--token` definition and `var(--token)` usage across a
/// page's parsed stylesheets. Only the edited document may receive writes;
/// sibling stylesheets contribute definitions and usage counts so token
/// rewrites stay faithful to consumers the edited file can't see.
struct CSSCustomPropertyTable {
  struct Definition {
    let ruleIndexPath: [Int]
    let valueText: String
    /// True for definitions on a top-level `:root`/`html` rule — the only
    /// ones that are unconditionally visible everywhere and therefore safe
    /// to reference or rewrite from any other rule. Definitions nested in
    /// media/support blocks apply conditionally, so the planner leaves them
    /// alone (except when the edit targets the very rule that defines them).
    let isRootScoped: Bool
    /// True when the definition lives in the document being edited — the
    /// only place a definition rewrite may land.
    let isInEditedDocument: Bool
  }

  private var definitions: [String: [Definition]] = [:]
  private var usages: [String: Int] = [:]

  init(document: CSSSourceDocument, siblings: [CSSSourceDocument] = []) {
    index(document, isEditedDocument: true)
    for sibling in siblings {
      index(sibling, isEditedDocument: false)
    }
  }

  private mutating func index(_ document: CSSSourceDocument, isEditedDocument: Bool) {
    for rule in document.allRules {
      let isRootScoped = rule.indexPath.count == 1
        && (rule.normalizedSelectorText.map { selector in
          CSSDeclarationEditPlanner.topLevelSplit(selector)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .allSatisfy { $0 == ":root" || $0 == "html" }
        } ?? false)
      for declaration in rule.declarations {
        if declaration.name.hasPrefix("--") {
          definitions[declaration.name, default: []].append(
            Definition(
              ruleIndexPath: rule.indexPath,
              valueText: declaration.valueText,
              isRootScoped: isRootScoped,
              isInEditedDocument: isEditedDocument
            )
          )
        }
        for reference in Self.varReferences(in: declaration.valueText) {
          usages[reference, default: 0] += 1
        }
      }
    }
  }

  /// Token names referenced via `var(...)` in a value, original case
  /// preserved (custom property names are case-sensitive).
  static func varReferences(in value: String) -> [String] {
    var references: [String] = []
    var searchRange = value.startIndex..<value.endIndex
    while let match = value.range(of: "var(", options: .caseInsensitive, range: searchRange) {
      var name = ""
      var index = match.upperBound
      while index < value.endIndex, value[index].isWhitespace {
        index = value.index(after: index)
      }
      while index < value.endIndex {
        let character = value[index]
        if character.isLetter || character.isNumber || character == "-" || character == "_" {
          name.append(character)
          index = value.index(after: index)
        } else {
          break
        }
      }
      if name.hasPrefix("--"), name.count > 2 {
        references.append(name)
      }
      searchRange = match.upperBound..<value.endIndex
    }
    return references
  }

  func usageCount(of token: String) -> Int {
    usages[token] ?? 0
  }

  /// The token's single plain-literal definition, or nil when it is
  /// undefined, defined more than once (e.g. media-query overrides or a
  /// sibling stylesheet redefining it), defined in terms of other
  /// functions/vars, defined outside the edited document (rewrites never
  /// cross files), or scoped somewhere the edited rule cannot rely on
  /// (anything but `:root`/`html` or the edited rule itself).
  func singleLiteralDefinition(of token: String, visibleFrom ruleIndexPath: [Int]) -> Definition? {
    guard let candidates = definitions[token], candidates.count == 1,
          let definition = candidates.first else { return nil }
    guard definition.isInEditedDocument else { return nil }
    guard definition.isRootScoped || definition.ruleIndexPath == ruleIndexPath else { return nil }
    let value = definition.valueText.lowercased()
    guard !value.contains("var("), !value.contains("calc("), !value.contains("env(") else { return nil }
    return definition
  }

  /// The definition a token-wide promotion may rewrite: the token's single
  /// project-wide definition, root-scoped, living in the edited document,
  /// holding a plain literal.
  func promotableDefinition(of token: String) -> Definition? {
    guard let candidates = definitions[token], candidates.count == 1,
          let definition = candidates.first,
          definition.isInEditedDocument,
          definition.isRootScoped else { return nil }
    let value = definition.valueText.lowercased()
    guard !value.contains("var("), !value.contains("calc("), !value.contains("env(") else { return nil }
    return definition
  }

  /// Resolves a token through single-definition chains (depth-limited) to a
  /// plain literal. Nil when any hop is ambiguous or non-literal.
  func resolvedLiteral(for token: String, depth: Int = 0) -> String? {
    guard depth < 8 else { return nil }
    guard let candidates = definitions[token], candidates.count == 1,
          let definition = candidates.first else { return nil }
    let value = definition.valueText.trimmingCharacters(in: .whitespacesAndNewlines)
    if let nested = CSSDeclarationEditPlanner.pureVarReference(value) {
      return resolvedLiteral(for: nested, depth: depth + 1)
    }
    guard !value.lowercased().contains("var(") else { return nil }
    return value.isEmpty ? nil : value
  }

  /// Root-scoped tokens whose resolved literal satisfies the given
  /// equivalence test, in stable name order so reattachment is
  /// deterministic. Only root-scoped definitions are offered because a new
  /// `var()` reference must resolve identically wherever the edited rule
  /// applies.
  func tokens(where isEquivalent: (String) -> Bool) -> [String] {
    definitions.keys.sorted().filter { token in
      guard let candidates = definitions[token], candidates.count == 1,
            candidates[0].isRootScoped,
            let resolved = resolvedLiteral(for: token) else { return false }
      return isEquivalent(resolved)
    }
  }
}

// MARK: - Colors

/// An sRGB color parsed from any of the notations the planner preserves.
struct CSSColorValue: Equatable {
  /// 0-255 channel values after rounding.
  let red: Int
  let green: Int
  let blue: Int
  /// 0-1, rounded to 3 decimals.
  let alpha: Double

  // MARK: Parsing

  static func parse(_ text: String) -> CSSColorValue? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.hasPrefix("#") {
      return parseHex(String(trimmed.dropFirst()))
    }
    if trimmed.hasPrefix("rgb(") || trimmed.hasPrefix("rgba(") {
      return parseFunctional(trimmed, isHSL: false)
    }
    if trimmed.hasPrefix("hsl(") || trimmed.hasPrefix("hsla(") {
      return parseFunctional(trimmed, isHSL: true)
    }
    if let keyword = Self.keywords[trimmed] {
      return keyword
    }
    return nil
  }

  private static func parseHex(_ digits: String) -> CSSColorValue? {
    guard digits.allSatisfy(\.isHexDigit) else { return nil }

    func channel(_ text: Substring) -> Int? { Int(text, radix: 16) }

    switch digits.count {
    case 3, 4:
      let expanded = digits.map { "\($0)\($0)" }.joined()
      return parseHex(expanded)
    case 6:
      guard let red = channel(digits.prefix(2)),
            let green = channel(digits.dropFirst(2).prefix(2)),
            let blue = channel(digits.dropFirst(4).prefix(2)) else { return nil }
      return CSSColorValue(red: red, green: green, blue: blue, alpha: 1)
    case 8:
      guard let red = channel(digits.prefix(2)),
            let green = channel(digits.dropFirst(2).prefix(2)),
            let blue = channel(digits.dropFirst(4).prefix(2)),
            let alphaByte = channel(digits.dropFirst(6).prefix(2)) else { return nil }
      return CSSColorValue(red: red, green: green, blue: blue, alpha: roundAlpha(Double(alphaByte) / 255))
    default:
      return nil
    }
  }

  private static func parseFunctional(_ text: String, isHSL: Bool) -> CSSColorValue? {
    guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
    let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])

    // Accept both comma syntax and modern space syntax with `/ alpha`.
    var components: [String]
    var alphaText: String?
    if inner.contains(",") {
      components = CSSDeclarationEditPlanner.topLevelSplit(inner).map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if components.count == 4 {
        alphaText = components.removeLast()
      }
    } else {
      let slashParts = inner.split(separator: "/", maxSplits: 1)
      components = slashParts[0].split(whereSeparator: \.isWhitespace).map(String.init)
      if slashParts.count == 2 {
        alphaText = slashParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    guard components.count == 3 else { return nil }

    func number(_ text: String) -> Double? {
      Double(text.hasSuffix("%") ? String(text.dropLast()) : text)
    }

    let alpha: Double
    if let alphaText {
      guard var parsedAlpha = number(alphaText) else { return nil }
      if alphaText.hasSuffix("%") { parsedAlpha /= 100 }
      alpha = roundAlpha(min(max(parsedAlpha, 0), 1))
    } else {
      alpha = 1
    }

    if isHSL {
      guard let hue = number(components[0].replacingOccurrences(of: "deg", with: "")),
            components[1].hasSuffix("%"), components[2].hasSuffix("%"),
            let saturation = number(components[1]),
            let lightness = number(components[2]) else { return nil }
      let (red, green, blue) = hslToRGB(hue: hue, saturation: saturation / 100, lightness: lightness / 100)
      return CSSColorValue(red: red, green: green, blue: blue, alpha: alpha)
    }

    func rgbChannel(_ text: String) -> Int? {
      guard let value = number(text) else { return nil }
      let scaled = text.hasSuffix("%") ? value / 100 * 255 : value
      return Int(min(max(scaled, 0), 255).rounded())
    }

    guard let red = rgbChannel(components[0]),
          let green = rgbChannel(components[1]),
          let blue = rgbChannel(components[2]) else { return nil }
    return CSSColorValue(red: red, green: green, blue: blue, alpha: alpha)
  }

  private static func roundAlpha(_ alpha: Double) -> Double {
    (alpha * 1000).rounded() / 1000
  }

  private static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> (Int, Int, Int) {
    let hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
    guard saturation > 0 else {
      let gray = Int((lightness * 255).rounded())
      return (gray, gray, gray)
    }
    let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
    let p = 2 * lightness - q

    func component(_ t: Double) -> Int {
      var t = t
      if t < 0 { t += 1 }
      if t > 1 { t -= 1 }
      let value: Double
      if t < 1 / 6 { value = p + (q - p) * 6 * t }
      else if t < 1 / 2 { value = q }
      else if t < 2 / 3 { value = p + (q - p) * (2 / 3 - t) * 6 }
      else { value = p }
      return Int((value * 255).rounded())
    }

    return (component(hue + 1 / 3), component(hue), component(hue - 1 / 3))
  }

  private func rgbToHSL() -> (hue: Int, saturation: Int, lightness: Int) {
    let red = Double(self.red) / 255
    let green = Double(self.green) / 255
    let blue = Double(self.blue) / 255
    let maxChannel = max(red, green, blue)
    let minChannel = min(red, green, blue)
    let lightness = (maxChannel + minChannel) / 2
    guard maxChannel != minChannel else {
      return (0, 0, Int((lightness * 100).rounded()))
    }
    let delta = maxChannel - minChannel
    let saturation = lightness > 0.5
      ? delta / (2 - maxChannel - minChannel)
      : delta / (maxChannel + minChannel)
    var hue: Double
    switch maxChannel {
    case red:
      hue = (green - blue) / delta + (green < blue ? 6 : 0)
    case green:
      hue = (blue - red) / delta + 2
    default:
      hue = (red - green) / delta + 4
    }
    hue *= 60
    return (Int(hue.rounded()), Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
  }

  // MARK: Formatting

  /// Renders this color in the same notation as an existing declared value.
  func formatted(like declared: String) -> String {
    let trimmed = declared.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()

    func alphaString() -> String {
      var text = String(format: "%.3f", alpha)
      while text.contains("."), text.hasSuffix("0") { text.removeLast() }
      if text.hasSuffix(".") { text.removeLast() }
      return text
    }

    if lowered.hasPrefix("#") {
      let usesUppercase = trimmed.dropFirst().contains(where: { $0.isLetter && $0.isUppercase })
      var hex = String(format: "%02x%02x%02x", red, green, blue)
      if alpha < 1 {
        hex += String(format: "%02x", Int((alpha * 255).rounded()))
      }
      return "#" + (usesUppercase ? hex.uppercased() : hex)
    }

    if lowered.hasPrefix("hsl") {
      let (hue, saturation, lightness) = rgbToHSL()
      let usesCommas = lowered.contains(",")
      if alpha < 1 {
        return usesCommas
          ? "hsla(\(hue), \(saturation)%, \(lightness)%, \(alphaString()))"
          : "hsl(\(hue) \(saturation)% \(lightness)% / \(alphaString()))"
      }
      return usesCommas
        ? "hsl(\(hue), \(saturation)%, \(lightness)%)"
        : "hsl(\(hue) \(saturation)% \(lightness)%)"
    }

    if lowered.hasPrefix("rgb") {
      let usesCommas = lowered.contains(",")
      if alpha < 1 {
        return usesCommas
          ? "rgba(\(red), \(green), \(blue), \(alphaString()))"
          : "rgb(\(red) \(green) \(blue) / \(alphaString()))"
      }
      return usesCommas
        ? "rgb(\(red), \(green), \(blue))"
        : "rgb(\(red) \(green) \(blue))"
    }

    // Keywords and anything else: emit lowercase hex (rgba when translucent).
    if alpha < 1 {
      return "rgba(\(red), \(green), \(blue), \(alphaString()))"
    }
    return "#" + String(format: "%02x%02x%02x", red, green, blue)
  }

  /// The common named colors, so keyword-valued declarations still get
  /// no-op detection and format-aware rewrites.
  static let keywords: [String: CSSColorValue] = [
    "transparent": CSSColorValue(red: 0, green: 0, blue: 0, alpha: 0),
    "black": CSSColorValue(red: 0, green: 0, blue: 0, alpha: 1),
    "white": CSSColorValue(red: 255, green: 255, blue: 255, alpha: 1),
    "red": CSSColorValue(red: 255, green: 0, blue: 0, alpha: 1),
    "green": CSSColorValue(red: 0, green: 128, blue: 0, alpha: 1),
    "blue": CSSColorValue(red: 0, green: 0, blue: 255, alpha: 1),
    "yellow": CSSColorValue(red: 255, green: 255, blue: 0, alpha: 1),
    "orange": CSSColorValue(red: 255, green: 165, blue: 0, alpha: 1),
    "purple": CSSColorValue(red: 128, green: 0, blue: 128, alpha: 1),
    "pink": CSSColorValue(red: 255, green: 192, blue: 203, alpha: 1),
    "gray": CSSColorValue(red: 128, green: 128, blue: 128, alpha: 1),
    "grey": CSSColorValue(red: 128, green: 128, blue: 128, alpha: 1),
    "silver": CSSColorValue(red: 192, green: 192, blue: 192, alpha: 1),
    "maroon": CSSColorValue(red: 128, green: 0, blue: 0, alpha: 1),
    "navy": CSSColorValue(red: 0, green: 0, blue: 128, alpha: 1),
    "teal": CSSColorValue(red: 0, green: 128, blue: 128, alpha: 1),
    "olive": CSSColorValue(red: 128, green: 128, blue: 0, alpha: 1),
    "lime": CSSColorValue(red: 0, green: 255, blue: 0, alpha: 1),
    "aqua": CSSColorValue(red: 0, green: 255, blue: 255, alpha: 1),
    "cyan": CSSColorValue(red: 0, green: 255, blue: 255, alpha: 1),
    "fuchsia": CSSColorValue(red: 255, green: 0, blue: 255, alpha: 1),
    "magenta": CSSColorValue(red: 255, green: 0, blue: 255, alpha: 1),
  ]
}
