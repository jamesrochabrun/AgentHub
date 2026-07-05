//
//  CSSSourceEditor.swift
//  AgentHub
//
//  Format-preserving CSS parsing and single-declaration editing for the
//  web preview's Tier-1 direct writes. Rules are indexed the way CSSOM
//  indexes cssRules so runtime provenance can be matched against files on
//  disk; edits are byte-range splices verified by re-parsing before any
//  caller writes them.
//

import Foundation

// MARK: - Models

struct CSSSourceDocument: Equatable, Sendable {
  let rules: [CSSSourceRule]

  func rule(at indexPath: [Int]) -> CSSSourceRule? {
    guard let firstIndex = indexPath.first, firstIndex < rules.count else { return nil }
    var current = rules[firstIndex]
    for index in indexPath.dropFirst() {
      guard index < current.children.count else { return nil }
      current = current.children[index]
    }
    return current
  }

  var allRules: [CSSSourceRule] {
    var collected: [CSSSourceRule] = []
    func walk(_ rule: CSSSourceRule) {
      collected.append(rule)
      rule.children.forEach(walk)
    }
    rules.forEach(walk)
    return collected
  }
}

struct CSSSourceRule: Equatable, Sendable {
  let indexPath: [Int]
  /// Raw prelude text (selector list, or at-rule including its name).
  let prelude: String
  let isAtRule: Bool
  /// UTF-8 offsets of the content between the braces. Empty for statement
  /// at-rules (`@import …;`).
  let bodyRange: Range<Int>
  let preludeRange: Range<Int>
  let declarations: [CSSSourceDeclaration]
  let children: [CSSSourceRule]

  /// Whitespace-collapsed, lowercased selector for proof comparison against
  /// runtime `selectorText`. Nil for at-rules.
  var normalizedSelectorText: String? {
    guard !isAtRule else { return nil }
    return CSSSourceEditor.normalizeSelector(prelude)
  }
}

struct CSSSourceDeclaration: Equatable, Sendable {
  /// Canonical property name: lowercased for standard properties, original
  /// case for `--custom-properties` (custom property names are
  /// case-sensitive per spec).
  let name: String
  /// Trimmed value text, excluding any `!important`.
  let valueText: String
  let isImportant: Bool
  /// UTF-8 offsets from the first byte of the name through the trailing
  /// semicolon when present, else through the last value byte.
  let fullRange: Range<Int>
  /// UTF-8 offsets of `valueText` within the source.
  let valueRange: Range<Int>
  let hasTrailingSemicolon: Bool
}

struct CSSDeclarationEdit: Equatable, Sendable {
  let ruleIndexPath: [Int]
  let property: String
  /// Nil removes the declaration.
  let value: String?
}

enum CSSSourceEditorError: Error, Equatable {
  case parseFailed(String)
  case ruleNotFound([Int])
  case postConditionFailed(String)
}

// MARK: - Protocol

protocol CSSSourceEditing: Sendable {
  func parse(_ source: String) throws -> CSSSourceDocument
  func applyingDeclarationEdit(_ edit: CSSDeclarationEdit, to source: String) throws -> String
}

// MARK: - Editor

struct CSSSourceEditor: CSSSourceEditing {

  func parse(_ source: String) throws -> CSSSourceDocument {
    let bytes = Array(source.utf8)
    var cursor = 0
    let rules = try Self.parseRuleList(
      bytes: bytes,
      cursor: &cursor,
      end: bytes.count,
      indexPathPrefix: []
    )
    Self.skipWhitespaceAndComments(bytes, &cursor, end: bytes.count)
    guard cursor >= bytes.count else {
      throw CSSSourceEditorError.parseFailed("Unexpected content at offset \(cursor)")
    }
    return CSSSourceDocument(rules: rules)
  }

  func applyingDeclarationEdit(_ edit: CSSDeclarationEdit, to source: String) throws -> String {
    let document = try parse(source)
    guard let rule = document.rule(at: edit.ruleIndexPath), !rule.isAtRule || !rule.bodyRange.isEmpty else {
      throw CSSSourceEditorError.ruleNotFound(edit.ruleIndexPath)
    }

    let propertyName = Self.canonicalPropertyName(edit.property)
    var bytes = Array(source.utf8)
    let matching = rule.declarations.filter { $0.name == propertyName }

    if let newValue = edit.value?.trimmingCharacters(in: .whitespacesAndNewlines), !newValue.isEmpty {
      if let target = matching.last {
        bytes.replaceSubrange(target.valueRange, with: Array(newValue.utf8))
      } else {
        try Self.insertDeclaration(
          named: edit.property,
          value: newValue,
          into: &bytes,
          rule: rule
        )
      }
    } else if let target = matching.last {
      Self.removeDeclaration(target, from: &bytes)
    } else {
      // Removing a declaration that does not exist is a no-op.
      return source
    }

    guard let edited = String(bytes: bytes, encoding: .utf8) else {
      throw CSSSourceEditorError.postConditionFailed("Edited bytes are not valid UTF-8")
    }

    try Self.verifyPostConditions(
      original: document,
      editedSource: edited,
      edit: edit,
      editor: self
    )

    return edited
  }

  // MARK: - Property names

  /// Standard property names are case-insensitive and canonicalize to
  /// lowercase; custom properties (`--x`) are case-sensitive and keep their
  /// original spelling.
  static func canonicalPropertyName(_ name: String) -> String {
    name.hasPrefix("--") ? name : name.lowercased()
  }

  // MARK: - Selector normalization

  static func normalizeSelector(_ selector: String) -> String {
    var collapsed = selector
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    for combinator in [",", ">", "+", "~"] {
      collapsed = collapsed.replacingOccurrences(of: " \(combinator)", with: combinator)
      collapsed = collapsed.replacingOccurrences(of: "\(combinator) ", with: combinator)
    }
    return collapsed
  }

  // MARK: - Parsing

  private static func parseRuleList(
    bytes: [UInt8],
    cursor: inout Int,
    end: Int,
    indexPathPrefix: [Int]
  ) throws -> [CSSSourceRule] {
    var rules: [CSSSourceRule] = []

    while true {
      skipWhitespaceAndComments(bytes, &cursor, end: end)
      guard cursor < end else { break }
      guard bytes[cursor] != UInt8(ascii: "}") else {
        throw CSSSourceEditorError.parseFailed("Unbalanced closing brace at offset \(cursor)")
      }

      let rule = try parseRule(
        bytes: bytes,
        cursor: &cursor,
        end: end,
        indexPath: indexPathPrefix + [rules.count]
      )
      rules.append(rule)
    }

    return rules
  }

  private static func parseRule(
    bytes: [UInt8],
    cursor: inout Int,
    end: Int,
    indexPath: [Int]
  ) throws -> CSSSourceRule {
    let preludeStart = cursor
    guard let boundary = scanToBlockOrStatementEnd(bytes, from: cursor, end: end) else {
      throw CSSSourceEditorError.parseFailed("Rule starting at offset \(cursor) has no body or terminator")
    }

    let preludeEnd = trimmedEnd(bytes, from: preludeStart, to: boundary.position)
    let prelude = string(bytes, preludeStart..<preludeEnd)
    let isAtRule = prelude.hasPrefix("@")

    if boundary.isStatement {
      guard isAtRule else {
        throw CSSSourceEditorError.parseFailed("Unexpected statement at offset \(preludeStart)")
      }
      cursor = boundary.position + 1
      return CSSSourceRule(
        indexPath: indexPath,
        prelude: prelude,
        isAtRule: true,
        bodyRange: boundary.position..<boundary.position,
        preludeRange: preludeStart..<preludeEnd,
        declarations: [],
        children: []
      )
    }

    let bodyStart = boundary.position + 1
    guard let closeBrace = matchingCloseBrace(bytes, openBrace: boundary.position, end: end) else {
      throw CSSSourceEditorError.parseFailed("Unbalanced open brace at offset \(boundary.position)")
    }

    let contents = try parseBlockContents(
      bytes: bytes,
      bodyRange: bodyStart..<closeBrace,
      indexPathPrefix: indexPath
    )

    cursor = closeBrace + 1
    return CSSSourceRule(
      indexPath: indexPath,
      prelude: prelude,
      isAtRule: isAtRule,
      bodyRange: bodyStart..<closeBrace,
      preludeRange: preludeStart..<preludeEnd,
      declarations: contents.declarations,
      children: contents.children
    )
  }

  private static func parseBlockContents(
    bytes: [UInt8],
    bodyRange: Range<Int>,
    indexPathPrefix: [Int]
  ) throws -> (declarations: [CSSSourceDeclaration], children: [CSSSourceRule]) {
    var declarations: [CSSSourceDeclaration] = []
    var children: [CSSSourceRule] = []
    var cursor = bodyRange.lowerBound

    while true {
      skipWhitespaceAndComments(bytes, &cursor, end: bodyRange.upperBound)
      guard cursor < bodyRange.upperBound else { break }

      guard let boundary = scanToBlockOrStatementEnd(bytes, from: cursor, end: bodyRange.upperBound) else {
        // Trailing declaration without a semicolon.
        if let declaration = try parseDeclaration(
          bytes: bytes,
          chunk: cursor..<bodyRange.upperBound,
          hasTrailingSemicolon: false
        ) {
          declarations.append(declaration)
        }
        cursor = bodyRange.upperBound
        break
      }

      if boundary.isStatement {
        let chunkStart = cursor
        cursor = boundary.position + 1
        if bytes[chunkStart] == UInt8(ascii: "@") {
          children.append(CSSSourceRule(
            indexPath: indexPathPrefix + [children.count],
            prelude: string(bytes, chunkStart..<trimmedEnd(bytes, from: chunkStart, to: boundary.position)),
            isAtRule: true,
            bodyRange: boundary.position..<boundary.position,
            preludeRange: chunkStart..<trimmedEnd(bytes, from: chunkStart, to: boundary.position),
            declarations: [],
            children: []
          ))
        } else if let declaration = try parseDeclaration(
          bytes: bytes,
          chunk: chunkStart..<boundary.position,
          hasTrailingSemicolon: true
        ) {
          declarations.append(declaration)
        }
      } else {
        var childCursor = cursor
        let child = try parseRule(
          bytes: bytes,
          cursor: &childCursor,
          end: bodyRange.upperBound,
          indexPath: indexPathPrefix + [children.count]
        )
        children.append(child)
        cursor = childCursor
      }
    }

    return (declarations, children)
  }

  private static func parseDeclaration(
    bytes: [UInt8],
    chunk: Range<Int>,
    hasTrailingSemicolon: Bool
  ) throws -> CSSSourceDeclaration? {
    var start = chunk.lowerBound
    skipWhitespaceAndComments(bytes, &start, end: chunk.upperBound)
    let valueEndLimit = trimmedEnd(bytes, from: start, to: chunk.upperBound)
    guard start < valueEndLimit else { return nil }

    guard let colon = scanForColon(bytes, from: start, end: valueEndLimit) else {
      throw CSSSourceEditorError.parseFailed("Declaration without a colon at offset \(start)")
    }

    let nameEnd = trimmedEnd(bytes, from: start, to: colon)
    let name = canonicalPropertyName(string(bytes, start..<nameEnd))
    guard !name.isEmpty else {
      throw CSSSourceEditorError.parseFailed("Declaration with empty property name at offset \(start)")
    }

    var valueStart = colon + 1
    skipWhitespaceAndComments(bytes, &valueStart, end: valueEndLimit)

    var valueEnd = valueEndLimit
    var isImportant = false
    let rawValue = string(bytes, valueStart..<valueEndLimit)
    if let importantRange = rawValue.range(
      of: #"!\s*important\s*$"#,
      options: [.regularExpression, .caseInsensitive]
    ) {
      isImportant = true
      let importantByteOffset = String(rawValue[..<importantRange.lowerBound]).utf8.count
      valueEnd = trimmedEnd(bytes, from: valueStart, to: valueStart + importantByteOffset)
    }

    let fullEnd = hasTrailingSemicolon ? chunk.upperBound + 1 : valueEndLimit
    return CSSSourceDeclaration(
      name: name,
      valueText: string(bytes, valueStart..<valueEnd),
      isImportant: isImportant,
      fullRange: start..<fullEnd,
      valueRange: valueStart..<valueEnd,
      hasTrailingSemicolon: hasTrailingSemicolon
    )
  }

  // MARK: - Editing

  private static func insertDeclaration(
    named property: String,
    value: String,
    into bytes: inout [UInt8],
    rule: CSSSourceRule
  ) throws {
    let indentation = declarationIndentation(bytes: bytes, rule: rule)
    let declarationText = "\(property): \(value);"

    if let lastDeclaration = rule.declarations.last {
      var insertion = "\n\(indentation)\(declarationText)"
      var position = lastDeclaration.fullRange.upperBound
      if !lastDeclaration.hasTrailingSemicolon {
        insertion = ";" + insertion
        position = lastDeclaration.fullRange.upperBound
      }
      bytes.insert(contentsOf: Array(insertion.utf8), at: position)
      return
    }

    // No declarations yet: insert at the start of the body, before any
    // nested child rules.
    let insertion = "\n\(indentation)\(declarationText)"
    bytes.insert(contentsOf: Array(insertion.utf8), at: rule.bodyRange.lowerBound)
  }

  private static func removeDeclaration(_ declaration: CSSSourceDeclaration, from bytes: inout [UInt8]) {
    var start = declaration.fullRange.lowerBound
    var end = declaration.fullRange.upperBound

    // Absorb leading line whitespace when the declaration starts its line.
    var lineStart = start
    while lineStart > 0, bytes[lineStart - 1] == UInt8(ascii: " ") || bytes[lineStart - 1] == UInt8(ascii: "\t") {
      lineStart -= 1
    }
    let startsLine = lineStart == 0 || bytes[lineStart - 1] == UInt8(ascii: "\n")

    // Absorb the trailing newline when the rest of the line is blank.
    var trailing = end
    while trailing < bytes.count, bytes[trailing] == UInt8(ascii: " ") || bytes[trailing] == UInt8(ascii: "\t") {
      trailing += 1
    }
    if startsLine, trailing < bytes.count, bytes[trailing] == UInt8(ascii: "\n") {
      start = lineStart
      end = trailing + 1
    }

    bytes.removeSubrange(start..<end)
  }

  private static func declarationIndentation(bytes: [UInt8], rule: CSSSourceRule) -> String {
    if let firstDeclaration = rule.declarations.first {
      var lineStart = firstDeclaration.fullRange.lowerBound
      while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") {
        lineStart -= 1
      }
      let prefix = string(bytes, lineStart..<firstDeclaration.fullRange.lowerBound)
      if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
        return prefix
      }
    }

    var ruleLineStart = rule.preludeRange.lowerBound
    while ruleLineStart > 0, bytes[ruleLineStart - 1] != UInt8(ascii: "\n") {
      ruleLineStart -= 1
    }
    let rulePrefix = string(bytes, ruleLineStart..<rule.preludeRange.lowerBound)
    let baseIndent = rulePrefix.allSatisfy({ $0 == " " || $0 == "\t" }) ? rulePrefix : ""
    return baseIndent + "  "
  }

  // MARK: - Post-conditions

  private static func verifyPostConditions(
    original: CSSSourceDocument,
    editedSource: String,
    edit: CSSDeclarationEdit,
    editor: CSSSourceEditor
  ) throws {
    let edited: CSSSourceDocument
    do {
      edited = try editor.parse(editedSource)
    } catch {
      throw CSSSourceEditorError.postConditionFailed("Edited CSS no longer parses: \(error)")
    }

    let originalRules = original.allRules
    let editedRules = edited.allRules
    guard originalRules.count == editedRules.count else {
      throw CSSSourceEditorError.postConditionFailed(
        "Rule count changed (\(originalRules.count) → \(editedRules.count))"
      )
    }

    let propertyName = canonicalPropertyName(edit.property)

    for (originalRule, editedRule) in zip(originalRules, editedRules) {
      guard originalRule.indexPath == editedRule.indexPath,
            normalizeSelector(originalRule.prelude) == normalizeSelector(editedRule.prelude) else {
        throw CSSSourceEditorError.postConditionFailed(
          "Rule structure changed at \(originalRule.indexPath)"
        )
      }

      let isTargetRule = originalRule.indexPath == edit.ruleIndexPath
      let originalDeclarations = originalRule.declarations.map { ($0.name, $0.valueText, $0.isImportant) }
      let editedDeclarations = editedRule.declarations.map { ($0.name, $0.valueText, $0.isImportant) }

      if !isTargetRule {
        guard originalDeclarations.elementsEqual(editedDeclarations, by: ==) else {
          throw CSSSourceEditorError.postConditionFailed(
            "Declarations changed in untouched rule at \(originalRule.indexPath)"
          )
        }
        continue
      }

      let originalOthers = originalDeclarations.filter { $0.0 != propertyName }
      let editedOthers = editedDeclarations.filter { $0.0 != propertyName }
      guard originalOthers.elementsEqual(editedOthers, by: ==) else {
        throw CSSSourceEditorError.postConditionFailed(
          "Untouched declarations changed in the target rule"
        )
      }

      let editedTargets = editedRule.declarations.filter { $0.name == propertyName }
      if let newValue = edit.value?.trimmingCharacters(in: .whitespacesAndNewlines), !newValue.isEmpty {
        guard editedTargets.last?.valueText == newValue else {
          throw CSSSourceEditorError.postConditionFailed(
            "Target declaration does not carry the requested value"
          )
        }
      } else {
        let originalTargets = originalRule.declarations.filter { $0.name == propertyName }
        guard editedTargets.count == max(0, originalTargets.count - 1) else {
          throw CSSSourceEditorError.postConditionFailed(
            "Removal did not remove exactly one declaration"
          )
        }
      }
    }
  }

  // MARK: - Scanning primitives

  private struct Boundary {
    let position: Int
    let isStatement: Bool
  }

  /// Scans for the first `{` or `;` outside comments, strings, and parens.
  private static func scanToBlockOrStatementEnd(_ bytes: [UInt8], from start: Int, end: Int) -> Boundary? {
    var i = start
    var parenDepth = 0
    var bracketDepth = 0

    while i < end {
      let byte = bytes[i]
      if byte == UInt8(ascii: "/"), i + 1 < end, bytes[i + 1] == UInt8(ascii: "*") {
        i = skipComment(bytes, from: i, end: end)
        continue
      }
      if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
        i = skipString(bytes, from: i, end: end)
        continue
      }
      switch byte {
      case UInt8(ascii: "("): parenDepth += 1
      case UInt8(ascii: ")"): parenDepth = max(0, parenDepth - 1)
      case UInt8(ascii: "["): bracketDepth += 1
      case UInt8(ascii: "]"): bracketDepth = max(0, bracketDepth - 1)
      case UInt8(ascii: "{") where parenDepth == 0 && bracketDepth == 0:
        return Boundary(position: i, isStatement: false)
      case UInt8(ascii: ";") where parenDepth == 0 && bracketDepth == 0:
        return Boundary(position: i, isStatement: true)
      default:
        break
      }
      i += 1
    }

    return nil
  }

  private static func matchingCloseBrace(_ bytes: [UInt8], openBrace: Int, end: Int) -> Int? {
    var i = openBrace + 1
    var depth = 1

    while i < end {
      let byte = bytes[i]
      if byte == UInt8(ascii: "/"), i + 1 < end, bytes[i + 1] == UInt8(ascii: "*") {
        i = skipComment(bytes, from: i, end: end)
        continue
      }
      if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
        i = skipString(bytes, from: i, end: end)
        continue
      }
      if byte == UInt8(ascii: "{") {
        depth += 1
      } else if byte == UInt8(ascii: "}") {
        depth -= 1
        if depth == 0 { return i }
      }
      i += 1
    }

    return nil
  }

  private static func scanForColon(_ bytes: [UInt8], from start: Int, end: Int) -> Int? {
    var i = start
    var parenDepth = 0

    while i < end {
      let byte = bytes[i]
      if byte == UInt8(ascii: "/"), i + 1 < end, bytes[i + 1] == UInt8(ascii: "*") {
        i = skipComment(bytes, from: i, end: end)
        continue
      }
      if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
        i = skipString(bytes, from: i, end: end)
        continue
      }
      if byte == UInt8(ascii: "(") { parenDepth += 1 }
      if byte == UInt8(ascii: ")") { parenDepth = max(0, parenDepth - 1) }
      if byte == UInt8(ascii: ":"), parenDepth == 0 {
        return i
      }
      i += 1
    }

    return nil
  }

  private static func skipComment(_ bytes: [UInt8], from start: Int, end: Int) -> Int {
    var i = start + 2
    while i + 1 < end {
      if bytes[i] == UInt8(ascii: "*"), bytes[i + 1] == UInt8(ascii: "/") {
        return i + 2
      }
      i += 1
    }
    return end
  }

  private static func skipString(_ bytes: [UInt8], from start: Int, end: Int) -> Int {
    let quote = bytes[start]
    var i = start + 1
    while i < end {
      if bytes[i] == UInt8(ascii: "\\") {
        i += 2
        continue
      }
      if bytes[i] == quote {
        return i + 1
      }
      i += 1
    }
    return end
  }

  private static func skipWhitespaceAndComments(_ bytes: [UInt8], _ cursor: inout Int, end: Int) {
    while cursor < end {
      let byte = bytes[cursor]
      if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
        || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
        cursor += 1
        continue
      }
      if byte == UInt8(ascii: "/"), cursor + 1 < end, bytes[cursor + 1] == UInt8(ascii: "*") {
        cursor = skipComment(bytes, from: cursor, end: end)
        continue
      }
      break
    }
  }

  private static func trimmedEnd(_ bytes: [UInt8], from start: Int, to end: Int) -> Int {
    var i = end
    while i > start {
      let byte = bytes[i - 1]
      if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
        || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
        i -= 1
        continue
      }
      break
    }
    return i
  }

  private static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String {
    guard range.lowerBound >= 0, range.upperBound <= bytes.count, range.lowerBound <= range.upperBound else {
      return ""
    }
    return String(bytes: bytes[range], encoding: .utf8) ?? ""
  }
}
