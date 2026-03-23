//
//  LocalhostURLNormalizer.swift
//  AgentHub
//
//  Normalizes localhost preview URLs extracted from agent output so the
//  embedded preview follows meaningful routes instead of markdown wildcards.
//

import Foundation

enum LocalhostURLNormalizer {
  private static let localhostPattern = #"https?://(?:localhost|127\.0\.0\.1):\d+[^\s<>"'`]*"#
  private static let trailingNoiseCharacters = CharacterSet(charactersIn: ".,;:)]>`\"'*")
  private static let decorativeWildcardCharacters = CharacterSet(charactersIn: "*.")

  static func extractFirstURL(from text: String) -> URL? {
    guard let regex = try? NSRegularExpression(pattern: localhostPattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range, in: text) else {
      return nil
    }

    return sanitize(String(text[range]))
  }

  static func extractLastURL(from text: String) -> URL? {
    guard let regex = try? NSRegularExpression(pattern: localhostPattern) else {
      return nil
    }

    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

    for match in matches.reversed() {
      guard let range = Range(match.range, in: text),
            let sanitizedURL = sanitize(String(text[range])) else {
        continue
      }

      return sanitizedURL
    }

    return nil
  }

  static func sanitize(_ url: URL) -> URL? {
    sanitize(url.absoluteString)
  }

  static func sanitize(_ candidate: String) -> URL? {
    let trimmedCandidate = trimTrailingNoise(
      from: candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    )

    guard !trimmedCandidate.isEmpty,
          var components = URLComponents(string: trimmedCandidate),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host?.lowercased(),
          host == "localhost" || host == "127.0.0.1",
          components.port != nil else {
      return nil
    }

    components.scheme = scheme
    components.host = host
    components.percentEncodedPath = sanitizePath(components.percentEncodedPath)
    return components.url
  }

  private static func sanitizePath(_ path: String) -> String {
    guard !path.isEmpty else { return "" }

    var segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

    while let last = segments.last {
      let trimmedLast = trimTrailingNoise(from: last)
      if trimmedLast != last {
        segments[segments.count - 1] = trimmedLast
      }

      guard let normalizedLast = segments.last else { break }

      if normalizedLast.isEmpty {
        if segments.count == 1 {
          return ""
        }
        segments.removeLast()
        continue
      }

      if isDecorativeWildcardSegment(normalizedLast) {
        segments.removeLast()
        continue
      }

      break
    }

    while let last = segments.last, last.isEmpty, segments.count > 1 {
      segments.removeLast()
    }

    let meaningfulSegments = segments.filter { !$0.isEmpty }
    guard !meaningfulSegments.isEmpty else { return "" }

    let normalizedPath = meaningfulSegments.joined(separator: "/")
    return path.hasPrefix("/") ? "/\(normalizedPath)" : normalizedPath
  }

  private static func isDecorativeWildcardSegment(_ segment: String) -> Bool {
    let stripped = segment.trimmingCharacters(in: decorativeWildcardCharacters)
    return !segment.isEmpty && stripped.isEmpty
  }

  private static func trimTrailingNoise(from string: String) -> String {
    var result = string
    while let scalar = result.unicodeScalars.last,
          trailingNoiseCharacters.contains(scalar) {
      result.unicodeScalars.removeLast()
    }
    return result
  }
}
