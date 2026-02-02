//
//  CodexSearchService.swift
//  AgentHub
//
//  Lightweight search across Codex sessions.
//

import Foundation

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
    let lowercaseQuery = query.lowercased()
    var results: [SessionSearchResult] = []

    for (_, entry) in sessionIndex {
      if let filterPath = filterPath {
        guard entry.projectPath.hasPrefix(filterPath) || entry.projectPath == filterPath else {
          continue
        }
      }

      if entry.slug.lowercased().contains(lowercaseQuery) {
        results.append(makeResult(from: entry, matchedField: .slug, matchedText: entry.slug))
      } else if entry.projectPath.lowercased().contains(lowercaseQuery) {
        results.append(makeResult(from: entry, matchedField: .path, matchedText: entry.projectPath))
      } else if let branch = entry.gitBranch, branch.lowercased().contains(lowercaseQuery) {
        results.append(makeResult(from: entry, matchedField: .gitBranch, matchedText: branch))
      } else if let message = entry.firstMessage, message.lowercased().contains(lowercaseQuery) {
        results.append(makeResult(from: entry, matchedField: .firstMessage, matchedText: message))
      }
    }

    return results.sorted { $0.lastActivityAt > $1.lastActivityAt }
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

  // MARK: - Results

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

// MARK: - Protocol Conformance

extension CodexSearchService: SessionSearchServiceProtocol {}
