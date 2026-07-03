//
//  CSSSelectorSpecificity.swift
//  AgentHub
//
//  Specificity computation for the static-preview winner calculation.
//  Mirrors the in-page calculator in WebPreviewStyleProvenanceScript:
//  selectors with functional pseudo-classes we cannot score faithfully are
//  flagged so the caller degrades to agent-applied edits.
//

import Foundation

enum CSSSelectorSpecificity {

  /// True when the selector uses functional pseudo-classes whose specificity
  /// rules (:not/:is/:has take their argument's, :where is zero) this simple
  /// calculator does not model.
  static func hasComplexPseudo(_ selector: String) -> Bool {
    selector.range(
      of: #":(not|is|where|has|matches)\("#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  /// Computes `[ids, classes/attributes/pseudo-classes, types/pseudo-elements]`
  /// for one complex selector (no commas).
  static func compute(_ selector: String) -> [Int] {
    var a = 0, b = 0, c = 0
    var remaining = selector

    func consume(_ pattern: String, counting counter: inout Int) {
      while let range = remaining.range(of: pattern, options: .regularExpression) {
        counter += 1
        remaining.replaceSubrange(range, with: " ")
      }
    }

    consume(#"\[[^\]]*\]"#, counting: &b)
    consume(#"::[a-zA-Z-]+(\([^)]*\))?"#, counting: &c)
    consume(#":[a-zA-Z-]+(\([^)]*\))?"#, counting: &b)
    consume(#"#-?[_a-zA-Z][\w-]*"#, counting: &a)
    consume(#"\.-?[_a-zA-Z][\w-]*"#, counting: &b)
    consume(#"[_a-zA-Z][\w-]*"#, counting: &c)

    return [a, b, c]
  }

  /// Lexicographic comparison; positive when lhs is more specific.
  static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      if left != right { return left - right }
    }
    return 0
  }

  /// Splits a selector list on top-level commas (respects (), [], strings).
  static func selectorParts(_ prelude: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var parenDepth = 0
    var bracketDepth = 0
    var quote: Character?

    for character in prelude {
      if let activeQuote = quote {
        current.append(character)
        if character == activeQuote { quote = nil }
        continue
      }
      switch character {
      case "\"", "'":
        quote = character
        current.append(character)
      case "(":
        parenDepth += 1
        current.append(character)
      case ")":
        parenDepth = max(0, parenDepth - 1)
        current.append(character)
      case "[":
        bracketDepth += 1
        current.append(character)
      case "]":
        bracketDepth = max(0, bracketDepth - 1)
        current.append(character)
      case "," where parenDepth == 0 && bracketDepth == 0:
        parts.append(current)
        current = ""
      default:
        current.append(character)
      }
    }
    parts.append(current)

    return parts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
