//
//  ClaudeArtifactURLDetector.swift
//  AgentHub
//
//  Recognizes Claude artifact URLs in agent output so a published artifact can
//  be opened in its own side panel, the way a localhost URL opens web preview.
//

import Foundation

enum ClaudeArtifactURLDetector {
  private static let host = "claude.ai"
  private static let pathPrefix = "code/artifact"

  /// Cheap prefilter so the hot parse path skips the regex on ordinary text.
  private static let marker = "claude.ai/code/artifact/"

  /// The id class stops at prose and markdown punctuation, so a URL written as
  /// `…/artifact/abc).` or `…/artifact/abc.` still yields `abc`.
  private static let regex = try? NSRegularExpression(
    pattern: #"https?://(?:www\.)?claude\.ai/code/artifact/[A-Za-z0-9][A-Za-z0-9_-]{7,63}"#,
    options: [.caseInsensitive]
  )

  /// The artifact id in `url`, or nil when it isn't an artifact URL.
  static func identifier(from url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          let urlHost = url.host?.lowercased(),
          urlHost == host || urlHost == "www.\(host)" else {
      return nil
    }
    return identifier(fromPath: url.path)
  }

  /// Canonical URL for `candidate`, or nil when it isn't an artifact URL.
  ///
  /// Query and fragment are dropped: `?via=auto_preview` records how the link
  /// was surfaced, not which artifact it is, and keeping it would file the same
  /// artifact twice under two URLs.
  static func canonicalURL(from candidate: String) -> URL? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let identifier = identifier(from: url) else {
      return nil
    }
    return canonicalURL(forIdentifier: identifier)
  }

  static func canonicalURL(forIdentifier identifier: String) -> URL? {
    URL(string: "https://\(host)/\(pathPrefix)/\(identifier)")
  }

  /// Canonical artifact URLs mentioned in `text`, in first-seen order and
  /// deduped by id.
  static func extractAll(from text: String) -> [URL] {
    guard text.range(of: marker, options: [.caseInsensitive]) != nil, let regex else {
      return []
    }

    var seenIdentifiers = Set<String>()
    var urls: [URL] = []

    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let range = Range(match.range, in: text),
            let url = canonicalURL(from: String(text[range])),
            let identifier = identifier(from: url),
            seenIdentifiers.insert(identifier).inserted else {
        continue
      }
      urls.append(url)
    }

    return urls
  }

  /// True when the web view has been redirected to a sign-in page instead of
  /// the artifact — claude.ai's own login, or an identity provider it hands off
  /// to. Artifacts are private to the account, so this is the expected first
  /// stop for a signed-out web view.
  static func isSignInURL(_ url: URL) -> Bool {
    guard let urlHost = url.host?.lowercased() else { return false }

    if urlHost == "accounts.google.com" {
      return true
    }

    guard urlHost == host || urlHost == "www.\(host)",
          let firstSegment = url.path.split(separator: "/", omittingEmptySubsequences: true).first else {
      return false
    }

    return ["login", "signup", "sign-in", "magic-link", "oauth", "auth"].contains(firstSegment.lowercased())
  }

  private static func identifier(fromPath path: String) -> String? {
    let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard segments.count >= 3,
          segments[0].lowercased() == "code",
          segments[1].lowercased() == "artifact",
          isValidIdentifier(segments[2]) else {
      return nil
    }
    return segments[2]
  }

  private static func isValidIdentifier(_ candidate: String) -> Bool {
    guard (8...64).contains(candidate.count) else { return false }
    return candidate.allSatisfy { character in
      character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }
  }
}
