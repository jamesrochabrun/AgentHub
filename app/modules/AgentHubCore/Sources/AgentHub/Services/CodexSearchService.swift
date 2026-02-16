//
//  CodexSearchService.swift
//  AgentHub
//
//  Lightweight search across Codex sessions.
//

import Foundation
import os

public actor CodexSearchService {

  private let codexDataPath: String
  private var sessionIndex: [String: SessionIndexEntry] = [:]
  private var isIndexBuilt = false
  private var lastHistoryModTime: Date?

  public init(codexDataPath: String? = nil) {
    self.codexDataPath = codexDataPath ?? (NSHomeDirectory() + "/.codex")
  }

  public func search(query: String, filterPath: String? = nil) async -> [SessionSearchResult] {
    if !isIndexBuilt || shouldRebuildIndex() {
      await buildIndex()
    }

    guard !query.isEmpty else { return [] }

    let searchStart = ContinuousClock.now
    var results: [SessionSearchResult] = []

    for (_, entry) in sessionIndex {
      if let filterPath = filterPath {
        guard entry.projectPath.hasPrefix(filterPath) || entry.projectPath == filterPath else {
          continue
        }
      }

      // Score ALL fields and keep the best match
      var bestScore = 0
      var bestField: SearchMatchField = .slug
      var bestText = ""

      let candidates: [(String?, SearchMatchField, Int)] = [
        (entry.slug, .slug, 5),
        (entry.firstMessage, .firstMessage, 3),
        (entry.gitBranch, .gitBranch, 2),
        (entry.projectPath, .path, 0),
      ]

      for (text, field, fieldBonus) in candidates {
        guard let text, !text.isEmpty else { continue }
        if let match = SearchScoring.score(query: query, against: text) {
          let total = match.score + fieldBonus
          if total > bestScore {
            bestScore = total
            bestField = field
            bestText = text
          }
        }
      }

      if bestScore > 0 {
        results.append(SessionSearchResult(
          id: entry.sessionId,
          slug: entry.slug,
          projectPath: entry.projectPath,
          gitBranch: entry.gitBranch,
          firstMessage: entry.firstMessage,
          summaries: entry.summaries,
          lastActivityAt: entry.lastActivityAt,
          matchedField: bestField,
          matchedText: bestText,
          relevanceScore: bestScore
        ))
        AppLogger.search.debug("[CodexSearch] match: \(entry.slug) field=\(bestField.rawValue) score=\(bestScore)")
      }
    }

    // Sort by relevance descending, then by last activity as tiebreaker
    results.sort { lhs, rhs in
      if lhs.relevanceScore != rhs.relevanceScore {
        return lhs.relevanceScore > rhs.relevanceScore
      }
      return lhs.lastActivityAt > rhs.lastActivityAt
    }

    let elapsed = ContinuousClock.now - searchStart
    AppLogger.search.info("[CodexSearch] query=\(query) results=\(results.count) elapsed=\(elapsed)")

    return results
  }

  public func rebuildIndex() async {
    isIndexBuilt = false
    await buildIndex()
  }

  public func indexedSessionCount() async -> Int {
    sessionIndex.count
  }

  // MARK: - Index Building

  private func buildIndex() async {
    let buildStart = ContinuousClock.now
    sessionIndex.removeAll()

    let historyEntries = parseHistory()
    let historyBySession = Dictionary(grouping: historyEntries) { $0.sessionId }

    let sessionMetas = scanSessionMetas()

    for meta in sessionMetas {
      let history = historyBySession[meta.sessionId] ?? []
      let firstMessage = history.first?.text
      let lastActivity = [meta.lastActivityAt, history.last?.date]
        .compactMap { $0 }
        .max() ?? Date()

      let entry = SessionIndexEntry(
        sessionId: meta.sessionId,
        projectPath: meta.projectPath,
        slug: String(meta.sessionId.prefix(8)),
        gitBranch: meta.branch,
        firstMessage: firstMessage,
        summaries: [],
        lastActivityAt: lastActivity
      )

      sessionIndex[meta.sessionId] = entry
    }

    isIndexBuilt = true
    updateLastHistoryModTime()

    let indexCount = sessionIndex.count
    let elapsed = ContinuousClock.now - buildStart
    AppLogger.search.info("[CodexSearch] index built: \(indexCount) sessions in \(elapsed)")
  }

  // MARK: - Parsing

  private struct CodexHistoryEntry: Decodable, Sendable {
    let sessionId: String
    let timestamp: Int64
    let text: String

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case timestamp = "ts"
      case text
    }

    var date: Date {
      Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
  }

  private struct SessionMetaEntry {
    let sessionId: String
    let projectPath: String
    let branch: String?
    let lastActivityAt: Date?
  }

  private func parseHistory() -> [CodexHistoryEntry] {
    let historyPath = codexDataPath + "/history.jsonl"

    guard let data = FileManager.default.contents(atPath: historyPath),
          let content = String(data: data, encoding: .utf8) else {
      return []
    }

    let decoder = JSONDecoder()

    return content
      .components(separatedBy: .newlines)
      .compactMap { line -> CodexHistoryEntry? in
        guard !line.isEmpty,
              let jsonData = line.data(using: .utf8),
              let entry = try? decoder.decode(CodexHistoryEntry.self, from: jsonData) else {
          return nil
        }
        return entry
      }
  }

  private func scanSessionMetas() -> [SessionMetaEntry] {
    let files = CodexSessionFileScanner.listSessionFiles(codexDataPath: codexDataPath)
    var metas: [SessionMetaEntry] = []

    for path in files {
      guard let meta = CodexSessionFileScanner.readSessionMeta(from: path) else { continue }
      let lastActivity = fileModificationDate(path)
      metas.append(SessionMetaEntry(
        sessionId: meta.sessionId,
        projectPath: meta.projectPath,
        branch: meta.branch,
        lastActivityAt: lastActivity
      ))
    }

    return metas
  }

  private func fileModificationDate(_ path: String) -> Date? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let modDate = attrs[.modificationDate] as? Date else {
      return nil
    }
    return modDate
  }

  // MARK: - Index Invalidation

  private func shouldRebuildIndex() -> Bool {
    let historyPath = codexDataPath + "/history.jsonl"
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: historyPath),
          let modTime = attrs[.modificationDate] as? Date else {
      return true
    }

    if let last = lastHistoryModTime {
      return modTime > last
    }
    return true
  }

  private func updateLastHistoryModTime() {
    let historyPath = codexDataPath + "/history.jsonl"
    if let attrs = try? FileManager.default.attributesOfItem(atPath: historyPath),
       let modTime = attrs[.modificationDate] as? Date {
      lastHistoryModTime = modTime
    }
  }

}

// MARK: - Protocol Conformance

extension CodexSearchService: SessionSearchServiceProtocol {}
