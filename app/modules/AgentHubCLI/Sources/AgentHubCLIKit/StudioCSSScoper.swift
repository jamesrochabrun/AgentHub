import Foundation

/// Rewrites one variant's CSS so it applies only inside that variant's artboard.
///
/// A design canvas puts every variant in one document (the inspector bridge is
/// main-frame-only, so iframes are out), which means AgentHub owns CSS
/// isolation. `@scope` would be the clean answer but is unavailable on the
/// macOS 14 floor, so each rule is prefixed with the artboard selector instead.
///
/// Lives in the CLI kit rather than the app so the tool boundary and the
/// document writer share one implementation: CSS that cannot be scoped is
/// rejected when the agent files it, never rendered as a canvas that quietly
/// restyles its neighbours.
///
/// | Construct | Rewrite |
/// |---|---|
/// | `a, .b > c {…}` | `S a, S .b > c {…}` |
/// | leading `:root`, `html`, `body` | replaced by `S` |
/// | `@media`, `@supports`, `@container`, `@layer {}`, `@document` | kept; inner rules scoped |
/// | `@keyframes name` | renamed `name-{slug}`; `animation`/`animation-name` rewritten |
/// | `@font-face`, `@page`, `@property`, other block at-rules | kept verbatim |
/// | `@import` | dropped with a warning |
/// | unbalanced braces | `ParseError` |
public enum StudioCSSScoper {
  public struct Output: Equatable, Sendable {
    public let css: String
    public let warnings: [String]

    public init(css: String, warnings: [String]) {
      self.css = css
      self.warnings = warnings
    }
  }

  public struct ParseError: Error, Equatable, LocalizedError, Sendable {
    /// Character offset into the CSS where the problem was detected.
    public let offset: Int
    public let reason: String

    public var errorDescription: String? {
      "\(reason) at character \(offset)."
    }
  }

  /// The selector every rule of a variant is scoped under.
  public static func artboardSelector(forVariantName name: String) -> String {
    let escaped = name
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return ".studio-artboard[data-variant=\"\(escaped)\"]"
  }

  /// A CSS-identifier-safe form of a variant name, for renamed keyframes.
  public static func slug(_ name: String) -> String {
    var result = ""
    var lastWasDash = true
    for scalar in name.lowercased().unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
        result.unicodeScalars.append(scalar)
        lastWasDash = false
      } else if !lastWasDash {
        result.append("-")
        lastWasDash = true
      }
    }
    while result.hasSuffix("-") { result.removeLast() }
    return result.isEmpty ? "variant" : result
  }

  public static func scope(_ css: String, variantName: String) throws -> Output {
    var parser = Parser(css: Array(css))
    let nodes = try parser.parseRuleList(topLevel: true)

    let slug = slug(variantName)
    var keyframeNames: Set<String> = []
    collectKeyframeNames(in: nodes, into: &keyframeNames)
    let renames = Dictionary(uniqueKeysWithValues: keyframeNames.map { ($0, "\($0)-\(slug)") })

    var serializer = Serializer(
      scope: artboardSelector(forVariantName: variantName),
      renames: renames
    )
    let output = serializer.serialize(nodes, depth: 0)
    return Output(
      css: output.trimmingCharacters(in: .whitespacesAndNewlines),
      warnings: serializer.warnings
    )
  }

  // MARK: - Nodes

  indirect enum Node: Equatable {
    case style(selectors: String, block: String)
    case atBlock(prelude: String, children: [Node])
    case atRaw(prelude: String, block: String)
    case keyframes(prelude: String, name: String, block: String)
    case atStatement(String)
  }

  private static func collectKeyframeNames(in nodes: [Node], into names: inout Set<String>) {
    for node in nodes {
      switch node {
      case .keyframes(_, let name, _):
        names.insert(name)
      case .atBlock(_, let children):
        collectKeyframeNames(in: children, into: &names)
      case .style, .atRaw, .atStatement:
        continue
      }
    }
  }

  // MARK: - Parser

  struct Parser {
    let css: [Character]
    var index = 0

    init(css: [Character]) {
      self.css = css
    }

    private static let recursiveAtRules: Set<String> = [
      "media", "supports", "container", "layer", "document", "-moz-document",
    ]

    mutating func parseRuleList(topLevel: Bool) throws -> [Node] {
      var nodes: [Node] = []
      while true {
        try skipWhitespaceAndComments()
        guard index < css.count else {
          if topLevel { return nodes }
          throw ParseError(offset: index, reason: "Unbalanced braces: missing '}'")
        }
        let char = css[index]
        if char == "}" {
          if topLevel {
            throw ParseError(offset: index, reason: "Unbalanced braces: unexpected '}'")
          }
          index += 1
          return nodes
        }
        if char == ";" {
          index += 1
          continue
        }

        let preludeStart = index
        let (prelude, terminator) = try readPrelude()
        switch terminator {
        case ";":
          index += 1
          if prelude.hasPrefix("@") {
            nodes.append(.atStatement(prelude + ";"))
          }
          // A bare declaration at rule level is not valid CSS; drop it.
        case "{":
          index += 1
          nodes.append(try parseBlock(prelude: prelude, preludeStart: preludeStart))
        default:
          // End of input (or a closing brace) mid-prelude: nothing to keep.
          if !prelude.isEmpty, !topLevel {
            throw ParseError(offset: preludeStart, reason: "Unbalanced braces: missing '}'")
          }
        }
      }
    }

    private mutating func parseBlock(prelude: String, preludeStart: Int) throws -> Node {
      guard prelude.hasPrefix("@") else {
        return .style(selectors: prelude, block: try readRawBlock(openedAt: preludeStart))
      }

      let name = atRuleName(prelude)
      if Self.recursiveAtRules.contains(name) {
        return .atBlock(prelude: prelude, children: try parseRuleList(topLevel: false))
      }
      if name == "keyframes" || name.hasSuffix("-keyframes") {
        let keyframeName = prelude
          .dropFirst(name.count + 1)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return .keyframes(
          prelude: prelude,
          name: keyframeName,
          block: try readRawBlock(openedAt: preludeStart)
        )
      }
      return .atRaw(prelude: prelude, block: try readRawBlock(openedAt: preludeStart))
    }

    private func atRuleName(_ prelude: String) -> String {
      var name = ""
      for char in prelude.dropFirst() {
        if char.isLetter || char.isNumber || char == "-" || char == "_" {
          name.append(char)
        } else {
          break
        }
      }
      return name.lowercased()
    }

    /// Reads up to (not including) the next top-level `{`, `;`, or `}`.
    private mutating func readPrelude() throws -> (String, Character?) {
      var text = ""
      var depth = 0
      while index < css.count {
        let char = css[index]
        if char == "\"" || char == "'" {
          text += try readString()
          continue
        }
        if char == "/", index + 1 < css.count, css[index + 1] == "*" {
          try skipComment()
          continue
        }
        if char == "(" || char == "[" { depth += 1 }
        if char == ")" || char == "]" { depth = max(0, depth - 1) }
        if depth == 0, char == "{" || char == ";" || char == "}" {
          return (text.trimmingCharacters(in: .whitespacesAndNewlines), char)
        }
        text.append(char)
        index += 1
      }
      return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    /// Reads a balanced block body. `index` must sit just past the opening `{`;
    /// on return it sits just past the matching `}`.
    private mutating func readRawBlock(openedAt: Int) throws -> String {
      var text = ""
      var depth = 1
      while index < css.count {
        let char = css[index]
        if char == "\"" || char == "'" {
          text += try readString()
          continue
        }
        if char == "/", index + 1 < css.count, css[index + 1] == "*" {
          try skipComment()
          continue
        }
        if char == "{" { depth += 1 }
        if char == "}" {
          depth -= 1
          if depth == 0 {
            index += 1
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        }
        text.append(char)
        index += 1
      }
      throw ParseError(offset: openedAt, reason: "Unbalanced braces: missing '}'")
    }

    private mutating func readString() throws -> String {
      let quote = css[index]
      let start = index
      var text = String(quote)
      index += 1
      while index < css.count {
        let char = css[index]
        text.append(char)
        index += 1
        if char == "\\", index < css.count {
          text.append(css[index])
          index += 1
          continue
        }
        if char == quote { return text }
        if char == "\n" { break }
      }
      throw ParseError(offset: start, reason: "Unterminated string")
    }

    private mutating func skipComment() throws {
      let start = index
      index += 2
      while index + 1 < css.count {
        if css[index] == "*", css[index + 1] == "/" {
          index += 2
          return
        }
        index += 1
      }
      throw ParseError(offset: start, reason: "Unterminated comment")
    }

    private mutating func skipWhitespaceAndComments() throws {
      while index < css.count {
        let char = css[index]
        if char.isWhitespace {
          index += 1
        } else if char == "/", index + 1 < css.count, css[index + 1] == "*" {
          try skipComment()
        } else {
          return
        }
      }
    }
  }

  // MARK: - Serializer

  struct Serializer {
    let scope: String
    let renames: [String: String]
    var warnings: [String] = []

    init(scope: String, renames: [String: String]) {
      self.scope = scope
      self.renames = renames
    }

    mutating func serialize(_ nodes: [Node], depth: Int) -> String {
      let indent = String(repeating: "  ", count: depth)
      var lines: [String] = []
      for node in nodes {
        switch node {
        case .style(let selectors, let block):
          let scoped = scopeSelectorList(selectors)
          guard !scoped.isEmpty else { continue }
          lines.append("\(indent)\(scoped) {\n\(indentBlock(rewriteAnimations(block), indent: indent))\n\(indent)}")
        case .atBlock(let prelude, let children):
          lines.append("\(indent)\(prelude) {\n\(serialize(children, depth: depth + 1))\n\(indent)}")
        case .keyframes(let prelude, let name, let block):
          let renamed = renames[name] ?? name
          let head = prelude.hasSuffix(name)
            ? String(prelude.dropLast(name.count)) + renamed
            : prelude
          lines.append("\(indent)\(head) {\n\(indentBlock(block, indent: indent))\n\(indent)}")
        case .atRaw(let prelude, let block):
          let name = prelude.dropFirst().prefix { $0.isLetter || $0 == "-" }.lowercased()
          if !["font-face", "page", "property", "counter-style", "font-feature-values", "font-palette-values"].contains(name) {
            warnings.append("Left \(prelude.prefix(40)) unscoped: AgentHub does not know how to scope this at-rule.")
          }
          lines.append("\(indent)\(prelude) {\n\(indentBlock(block, indent: indent))\n\(indent)}")
        case .atStatement(let text):
          let lower = text.lowercased()
          if lower.hasPrefix("@import") {
            warnings.append("Dropped \(text.prefix(80)): imported CSS cannot be scoped to one variant. Inline the rules you need.")
          } else if lower.hasPrefix("@charset") || lower.hasPrefix("@namespace") {
            continue
          } else {
            lines.append("\(indent)\(text)")
          }
        }
      }
      return lines.joined(separator: "\n")
    }

    private func indentBlock(_ block: String, indent: String) -> String {
      block
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "\(indent)  \($0.trimmingCharacters(in: .whitespaces))" }
        .joined(separator: "\n")
    }

    // MARK: Selectors

    private static let rootAncestorPattern = try! NSRegularExpression(
      pattern: "^(?:html|:root)(?:[.#\\[:][^\\s>+~]*)?\\s*(?:>\\s*)?(?=(?:body|:root)(?:$|[\\s>+~.#\\[:]))",
      options: [.caseInsensitive]
    )
    private static let rootPattern = try! NSRegularExpression(
      pattern: "^(?:html|:root|body)(?=$|[\\s>+~.#\\[:(])",
      options: [.caseInsensitive]
    )

    func scopeSelectorList(_ list: String) -> String {
      var seen: Set<String> = []
      var scoped: [String] = []
      for raw in splitSelectors(list) {
        let selector = scopeSelector(raw)
        guard !selector.isEmpty, seen.insert(selector).inserted else { continue }
        scoped.append(selector)
      }
      return scoped.joined(separator: ", ")
    }

    func scopeSelector(_ raw: String) -> String {
      var selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !selector.isEmpty else { return "" }

      // `html body .x` → drop the `html`, so the following `body` becomes the
      // one scope instead of producing `S S .x`.
      selector = Self.rootAncestorPattern.stringByReplacingMatches(
        in: selector,
        range: NSRange(selector.startIndex..., in: selector),
        withTemplate: ""
      )

      let range = NSRange(selector.startIndex..., in: selector)
      if Self.rootPattern.firstMatch(in: selector, range: range) != nil {
        return Self.rootPattern.stringByReplacingMatches(
          in: selector,
          range: range,
          withTemplate: NSRegularExpression.escapedTemplate(for: scope)
        )
      }
      return "\(scope) \(selector)"
    }

    /// Splits on top-level commas — not the ones inside `:is(a, b)` or `[x="a,b"]`.
    private func splitSelectors(_ list: String) -> [String] {
      var parts: [String] = []
      var current = ""
      var depth = 0
      var quote: Character?
      var previous: Character?
      for char in list {
        if let openQuote = quote {
          current.append(char)
          if char == openQuote, previous != "\\" { quote = nil }
        } else if char == "\"" || char == "'" {
          quote = char
          current.append(char)
        } else if char == "(" || char == "[" {
          depth += 1
          current.append(char)
        } else if char == ")" || char == "]" {
          depth = max(0, depth - 1)
          current.append(char)
        } else if char == ",", depth == 0 {
          parts.append(current)
          current = ""
        } else {
          current.append(char)
        }
        previous = char
      }
      parts.append(current)
      return parts
    }

    // MARK: Animations

    private static let animationDeclarationPattern = try! NSRegularExpression(
      pattern: "((?:-webkit-)?animation(?:-name)?\\s*:\\s*)([^;}]*)",
      options: [.caseInsensitive]
    )

    private func rewriteAnimations(_ block: String) -> String {
      guard !renames.isEmpty else { return block }
      let nsBlock = block as NSString
      var result = ""
      var cursor = 0
      for match in Self.animationDeclarationPattern.matches(in: block, range: NSRange(location: 0, length: nsBlock.length)) {
        result += nsBlock.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        result += nsBlock.substring(with: match.range(at: 1))
        var value = nsBlock.substring(with: match.range(at: 2))
        for (old, new) in renames {
          guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\w-])\(NSRegularExpression.escapedPattern(for: old))(?![\\w-])"
          ) else { continue }
          value = regex.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: NSRegularExpression.escapedTemplate(for: new)
          )
        }
        result += value
        cursor = match.range.location + match.range.length
      }
      result += nsBlock.substring(from: cursor)
      return result
    }
  }
}
