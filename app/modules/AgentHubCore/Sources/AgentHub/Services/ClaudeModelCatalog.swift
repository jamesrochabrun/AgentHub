//
//  ClaudeModelCatalog.swift
//  AgentHub
//
//  Resolves the list of selectable Claude models without hardcoding versioned
//  ids. Claude has no offline "list models" command, so:
//
//  - Stable aliases (opus/sonnet/haiku) are always offered. These are
//    server-resolved — `--model opus` always maps to the latest Opus — so they
//    never go stale the way a pinned version would.
//  - Concrete versioned ids (e.g. claude-opus-4-8 vs claude-opus-4-7) are
//    discovered from the user's own local session JSONL history, which records
//    the resolved model for every turn. Nothing leaves the machine.
//

import Foundation

/// Provides the set of selectable Claude models.
public protocol ClaudeModelCatalogProviding: Sendable {
  func availableModels() async -> [AIModelOption]
}

public struct ClaudeModelCatalog: ClaudeModelCatalogProviding {
  /// Stable, server-resolved aliases. `--model opus` always maps to the latest
  /// Opus, so these never go stale the way a versioned id would.
  static let aliasOptions: [AIModelOption] = [
    AIModelOption(identifier: "opus", displayName: "Opus", detail: "Latest Opus (alias)"),
    AIModelOption(identifier: "sonnet", displayName: "Sonnet", detail: "Latest Sonnet (alias)"),
    AIModelOption(identifier: "haiku", displayName: "Haiku", detail: "Latest Haiku (alias)"),
  ]

  private let projectsDirectory: URL
  private let fileScanLimit: Int

  public init() {
    self.init(
      projectsDirectory: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects")
    )
  }

  init(projectsDirectory: URL, fileScanLimit: Int = 80) {
    self.projectsDirectory = projectsDirectory
    self.fileScanLimit = fileScanLimit
  }

  public func availableModels() async -> [AIModelOption] {
    let directory = projectsDirectory
    let limit = fileScanLimit
    let discovered = await Task.detached(priority: .utility) {
      Self.discoverModelIdentifiers(inProjectsDirectory: directory, fileScanLimit: limit)
    }.value

    let aliasIdentifiers = Set(Self.aliasOptions.map(\.identifier))
    let discoveredOptions = discovered
      .filter { !aliasIdentifiers.contains($0) }
      .map { AIModelOption(identifier: $0, displayName: $0, detail: "Used in your sessions") }

    return Self.aliasOptions + discoveredOptions
  }

  // MARK: - Discovery (pure, testable)

  /// Scans the most recently modified session JSONL files for resolved model
  /// ids, returning distinct valid Claude identifiers ordered most-recent-first.
  static func discoverModelIdentifiers(
    inProjectsDirectory directory: URL,
    fileScanLimit: Int = 80
  ) -> [String] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    var files: [(url: URL, modified: Date)] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
      files.append((url, values?.contentModificationDate ?? .distantPast))
    }

    let recentFiles = files
      .sorted { $0.modified > $1.modified }
      .prefix(fileScanLimit)
      .map(\.url)

    var ordered: [String] = []
    var seen = Set<String>()
    for url in recentFiles {
      guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for identifier in modelIdentifiers(inJSONL: contents) where seen.insert(identifier).inserted {
        ordered.append(identifier)
      }
    }
    return ordered
  }

  /// Distinct valid Claude model ids appearing in one JSONL document, in order.
  static func modelIdentifiers(inJSONL contents: String) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for line in contents.split(whereSeparator: \.isNewline) where line.contains("\"model\"") {
      for value in modelValues(inLine: String(line))
      where isValidModelIdentifier(value) && seen.insert(value).inserted {
        result.append(value)
      }
    }
    return result
  }

  /// Extracts every `"model":"…"` value from a single line.
  static func modelValues(inLine line: String) -> [String] {
    var values: [String] = []
    var search = line[...]
    while let keyRange = search.range(of: "\"model\"") {
      let afterKey = search[keyRange.upperBound...]
      guard let colon = afterKey.firstIndex(of: ":") else { break }
      let afterColon = afterKey[afterKey.index(after: colon)...]
      guard let openQuote = afterColon.firstIndex(of: "\"") else {
        search = afterColon
        continue
      }
      let valueStart = afterColon.index(after: openQuote)
      guard let closeQuote = afterColon[valueStart...].firstIndex(of: "\"") else { break }
      values.append(String(afterColon[valueStart..<closeQuote]))
      search = afterColon[afterColon.index(after: closeQuote)...]
    }
    return values
  }

  /// A value usable as a `--model` argument: lowercase, `claude-` prefixed, and
  /// free of spaces/brackets. Excludes display names ("Claude Opus 4.8"),
  /// beta-context suffixes ("…[1m]"), and non-Claude ids ("gpt-5.5").
  static func isValidModelIdentifier(_ value: String) -> Bool {
    guard value.hasPrefix("claude-") else { return false }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
    return value.allSatisfy { allowed.contains($0) }
  }
}
