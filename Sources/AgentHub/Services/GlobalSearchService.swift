//
//  GlobalSearchService.swift
//  AgentHub
//
//  Created by Assistant on 1/14/26.
//

import Foundation

// MARK: - GlobalSearchService

/// Service for searching across all Claude CLI sessions globally
/// Builds a lightweight index on first search and performs case-insensitive matching
public actor GlobalSearchService {

  // MARK: - Configuration

  private let claudeDataPath: String

  // MARK: - Index State

  private var sessionIndex: [String: SessionIndexEntry] = [:]
  private var isIndexBuilt = false
  private var lastHistoryModTime: Date?

  // MARK: - Initialization

  public init(claudeDataPath: String? = nil) {
    self.claudeDataPath = claudeDataPath ?? (NSHomeDirectory() + "/.claude")
  }

  // MARK: - Public API

  /// Searches across all sessions for the given query
  /// - Parameters:
  ///   - query: The search query (case-insensitive)
  ///   - filterPath: Optional path to filter results to a specific repository
  /// - Returns: Array of matching search results sorted by last activity
  public func search(query: String, filterPath: String? = nil) async -> [SessionSearchResult] {
    // Rebuild index if needed
    if !isIndexBuilt || shouldRebuildIndex() {
      await buildIndex()
    }

    guard !query.isEmpty else { return [] }

    let lowercaseQuery = query.lowercased()
    var results: [SessionSearchResult] = []

    for (_, entry) in sessionIndex {
      // Apply repository filter if set
      if let filterPath = filterPath {
        guard entry.projectPath.hasPrefix(filterPath) || entry.projectPath == filterPath else {
          continue
        }
      }

      // Check each searchable field in priority order
      if entry.slug.lowercased().contains(lowercaseQuery) {
        results.append(makeResult(from: entry, matchedField: .slug, matchedText: entry.slug))
      } else if entry.projectPath.lowercased().contains(lowercaseQuery) {
        results.append(makeResult(from: entry, matchedField: .path, matchedText: entry.projectPath))
      } else if let branch = entry.gitBranch, branch.lowercased().contains(lowercaseQuery) {
        results.append(makeResult(from: entry, matchedField: .gitBranch, matchedText: branch))
      } else if let matchedSummary = entry.summaries.first(where: { $0.lowercased().contains(lowercaseQuery) }) {
        results.append(makeResult(from: entry, matchedField: .summary, matchedText: matchedSummary))
      } else if let message = entry.firstMessage, message.lowercased().contains(lowercaseQuery) {
        results.append(makeResult(from: entry, matchedField: .firstMessage, matchedText: message))
      }
    }

    // Sort by last activity (most recent first)
    return results.sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  /// Forces a rebuild of the search index
  public func rebuildIndex() async {
    isIndexBuilt = false
    await buildIndex()
  }

  /// Returns the total number of indexed sessions
  public func indexedSessionCount() -> Int {
    sessionIndex.count
  }

  // MARK: - Index Building

  private func buildIndex() async {
    print("[GlobalSearchService] Building index...")
    let startTime = Date()

    sessionIndex.removeAll()

    // Step 1: Parse history.jsonl to discover all sessions
    let historyEntries = parseGlobalHistory()
    print("[GlobalSearchService] Found \(historyEntries.count) history entries")

    // Group by sessionId to get unique sessions
    let sessionGroups = Dictionary(grouping: historyEntries) { $0.sessionId }
    print("[GlobalSearchService] Found \(sessionGroups.count) unique sessions")

    // Step 2: For each session, extract metadata from session file
    for (sessionId, entries) in sessionGroups {
      guard let firstEntry = entries.first else { continue }

      let projectPath = firstEntry.project
      let lastActivityAt = entries.map { $0.date }.max() ?? Date()
      let firstMessage = entries.sorted { $0.timestamp < $1.timestamp }.first?.display

      // Read session file for slug, branch, and summaries
      if let metadata = parseSessionFile(sessionId: sessionId, projectPath: projectPath) {
        let entry = SessionIndexEntry(
          sessionId: sessionId,
          projectPath: projectPath,
          slug: metadata.slug,
          gitBranch: metadata.gitBranch,
          firstMessage: firstMessage,
          summaries: metadata.summaries,
          lastActivityAt: lastActivityAt
        )
        sessionIndex[sessionId] = entry
      }
    }

    isIndexBuilt = true
    updateLastHistoryModTime()

    let elapsed = Date().timeIntervalSince(startTime)
    print("[GlobalSearchService] Index built: \(sessionIndex.count) sessions in \(String(format: "%.2f", elapsed))s")
  }

  // MARK: - History Parsing

  private func parseGlobalHistory() -> [HistoryEntry] {
    let historyPath = claudeDataPath + "/history.jsonl"

    guard let data = FileManager.default.contents(atPath: historyPath),
          let content = String(data: data, encoding: .utf8) else {
      print("[GlobalSearchService] Could not read history.jsonl")
      return []
    }

    let decoder = JSONDecoder()

    return content
      .components(separatedBy: .newlines)
      .compactMap { line -> HistoryEntry? in
        guard !line.isEmpty,
              let jsonData = line.data(using: .utf8),
              let entry = try? decoder.decode(HistoryEntry.self, from: jsonData) else {
          return nil
        }
        return entry
      }
  }

  // MARK: - Session File Parsing

  private struct SessionMetadata {
    let slug: String
    let gitBranch: String?
    let summaries: [String]
  }

  private func parseSessionFile(sessionId: String, projectPath: String) -> SessionMetadata? {
    // Encode the project path for the folder name
    let encodedPath = encodeProjectPath(projectPath)
    let sessionFilePath = "\(claudeDataPath)/projects/\(encodedPath)/\(sessionId).jsonl"

    guard let data = FileManager.default.contents(atPath: sessionFilePath),
          let content = String(data: data, encoding: .utf8) else {
      // Session file doesn't exist - return placeholder
      return SessionMetadata(
        slug: String(sessionId.prefix(8)),
        gitBranch: nil,
        summaries: []
      )
    }

    var slug: String = String(sessionId.prefix(8))
    var gitBranch: String?
    var summaries: [String] = []

    let lines = content.components(separatedBy: .newlines)

    for line in lines {
      guard !line.isEmpty,
            let jsonData = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        continue
      }

      // Extract slug from first entry that has it
      if slug == String(sessionId.prefix(8)), let s = json["slug"] as? String {
        slug = s
      }

      // Extract gitBranch from first entry that has it
      if gitBranch == nil, let branch = json["gitBranch"] as? String {
        gitBranch = branch
      }

      // Extract summary entries
      if let type = json["type"] as? String, type == "summary",
         let summaryText = json["summary"] as? String {
        summaries.append(summaryText)
      }

      // Early exit if we have everything (optimization)
      if slug != String(sessionId.prefix(8)) && gitBranch != nil && summaries.count >= 10 {
        break
      }
    }

    return SessionMetadata(
      slug: slug,
      gitBranch: gitBranch,
      summaries: summaries
    )
  }

  // MARK: - Path Encoding

  /// Encodes a file path to the projects folder format
  /// `/Users/jamesrochabrun/Desktop/git/AgentHub` -> `-Users-jamesrochabrun-Desktop-git-AgentHub`
  private func encodeProjectPath(_ path: String) -> String {
    path.replacingOccurrences(of: "/", with: "-")
  }

  /// Decodes a projects folder name back to a file path
  /// `-Users-jamesrochabrun-Desktop-git-AgentHub` -> `/Users/jamesrochabrun/Desktop/git/AgentHub`
  private func decodeProjectPath(_ encodedName: String) -> String {
    "/" + encodedName.dropFirst().replacingOccurrences(of: "-", with: "/")
  }

  // MARK: - Index Invalidation

  private func shouldRebuildIndex() -> Bool {
    let historyPath = claudeDataPath + "/history.jsonl"
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: historyPath),
          let modTime = attrs[.modificationDate] as? Date else {
      return true
    }

    if let lastMod = lastHistoryModTime {
      return modTime > lastMod
    }
    return true
  }

  private func updateLastHistoryModTime() {
    let historyPath = claudeDataPath + "/history.jsonl"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: historyPath),
       let modTime = attrs[.modificationDate] as? Date {
      lastHistoryModTime = modTime
    }
  }

  // MARK: - Result Building

  private func makeResult(
    from entry: SessionIndexEntry,
    matchedField: SearchMatchField,
    matchedText: String
  ) -> SessionSearchResult {
    SessionSearchResult(
      id: entry.sessionId,
      slug: entry.slug,
      projectPath: entry.projectPath,
      gitBranch: entry.gitBranch,
      firstMessage: entry.firstMessage,
      summaries: entry.summaries,
      lastActivityAt: entry.lastActivityAt,
      matchedField: matchedField,
      matchedText: matchedText
    )
  }
}
