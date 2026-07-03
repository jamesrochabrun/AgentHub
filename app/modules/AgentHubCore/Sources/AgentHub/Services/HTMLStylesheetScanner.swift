//
//  HTMLStylesheetScanner.swift
//  AgentHub
//
//  Extracts, in document order, the stylesheet sources of an HTML file:
//  `<link rel="stylesheet" href>` references and inline `<style>` blocks.
//  Shared by the static-preview style resolver (winner computation) and the
//  direct-write coordinator (ordinal-addressed inline-block editing) so both
//  agree on block ordinals.
//

import Foundation

enum HTMLStylesheetSource: Equatable, Sendable {
  case linked(href: String, media: String?)
  /// UTF-8 offsets of the text between `<style …>` and `</style>`.
  case inlineBlock(contentRange: Range<Int>, ordinal: Int, media: String?)
}

enum HTMLStylesheetScanner {

  static func stylesheetSources(in html: String) -> [HTMLStylesheetSource] {
    var sources: [HTMLStylesheetSource] = []
    var styleOrdinal = 0

    let pattern = #"<(link|style)\b[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return []
    }

    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    for match in regex.matches(in: html, range: nsRange) {
      guard let tagRange = Range(match.range, in: html) else { continue }
      let tag = String(html[tagRange])

      if tag.lowercased().hasPrefix("<link") {
        guard let rel = attribute("rel", in: tag),
              rel.lowercased().split(whereSeparator: \.isWhitespace).contains("stylesheet"),
              let href = attribute("href", in: tag), !href.isEmpty else {
          continue
        }
        sources.append(.linked(href: href, media: attribute("media", in: tag)))
        continue
      }

      // <style …> … </style>
      guard let closeRange = html.range(
        of: "</style",
        options: [.caseInsensitive],
        range: tagRange.upperBound..<html.endIndex
      ) else {
        continue
      }

      let contentStart = utf8Offset(of: tagRange.upperBound, in: html)
      let contentEnd = utf8Offset(of: closeRange.lowerBound, in: html)
      sources.append(.inlineBlock(
        contentRange: contentStart..<contentEnd,
        ordinal: styleOrdinal,
        media: attribute("media", in: tag)
      ))
      styleOrdinal += 1
    }

    return sources
  }

  /// The content text of the inline `<style>` block with the given ordinal.
  static func inlineBlockContent(ordinal: Int, in html: String) -> (content: String, contentRange: Range<Int>)? {
    for source in stylesheetSources(in: html) {
      if case .inlineBlock(let contentRange, let blockOrdinal, _) = source, blockOrdinal == ordinal {
        let bytes = Array(html.utf8)
        guard contentRange.lowerBound >= 0, contentRange.upperBound <= bytes.count,
              let content = String(bytes: bytes[contentRange], encoding: .utf8) else {
          return nil
        }
        return (content, contentRange)
      }
    }
    return nil
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let nsRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    guard let match = regex.firstMatch(in: tag, range: nsRange),
          let valueRange = Range(match.range(at: 1), in: tag) else {
      return nil
    }
    var value = String(tag[valueRange])
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
      value = String(value.dropFirst().dropLast())
    }
    return value
  }

  private static func utf8Offset(of index: String.Index, in string: String) -> Int {
    string.utf8.distance(from: string.utf8.startIndex, to: index.samePosition(in: string.utf8) ?? string.utf8.startIndex)
  }
}
