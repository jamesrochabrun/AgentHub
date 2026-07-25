//
//  GitHubPullRequestURLReferenceCache.swift
//  AgentHubGitHub
//
//  Memoized lookup for PR references parsed out of session output.
//

import Foundation

/// Memoizes `GitHubPullRequestURLReference(urlString:)`.
///
/// Parsing is a pure function of the URL string, so this is a plain cache with
/// no invalidation. It exists because the sidebar's session list is rebuilt on
/// every monitor-state publish (up to 10 Hz per session) and each pass re-parsed
/// every detected resource link with `URLComponents` — measurable main-thread
/// cost inside a SwiftUI `body`.
///
/// Main-actor isolated because every caller is a view or view model; that also
/// makes the unsynchronized storage safe.
@MainActor
public enum GitHubPullRequestURLReferenceCache {
  /// Detected links are dominated by a handful of URLs repeated across sessions,
  /// so a small cache covers effectively every lookup.
  static let capacity = 512

  /// `nil` values are cached too — most detected links are not PR URLs, and
  /// re-parsing those is exactly the cost this avoids.
  private static var entries: [String: GitHubPullRequestURLReference?] = [:]

  /// The parsed reference for `urlString`, or `nil` if it is not a GitHub PR URL.
  public static func reference(for urlString: String) -> GitHubPullRequestURLReference? {
    if let cached = entries[urlString] {
      return cached
    }
    // Flush wholesale rather than tracking an LRU: entries are tiny, lookups are
    // hot, and the working set only grows when a session emits many new links.
    if entries.count >= capacity {
      entries.removeAll(keepingCapacity: true)
    }
    let parsed = GitHubPullRequestURLReference(urlString: urlString)
    entries[urlString] = parsed
    return parsed
  }

  /// The PR references among `urlStrings`, preserving order and dropping non-PR URLs.
  public static func references(in urlStrings: [String]) -> [GitHubPullRequestURLReference] {
    urlStrings.compactMap { reference(for: $0) }
  }

  /// Test hook — production code never needs to invalidate a pure memo.
  public static func resetForTesting() {
    entries.removeAll()
  }

  /// Test hook for asserting cache occupancy.
  static var cachedEntryCount: Int {
    entries.count
  }
}
