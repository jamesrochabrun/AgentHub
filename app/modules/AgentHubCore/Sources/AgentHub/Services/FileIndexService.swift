//
//  FileIndexService.swift
//  AgentHub
//
//  Actor-based file index service with gitignore support and fuzzy search.
//

import Foundation

// MARK: - FileIndexService

/// Scans project directories, respects .gitignore, caches the index, and provides fuzzy search.
public actor FileIndexService {

  // MARK: - Shared Instance

  public static let shared = FileIndexService()

  // MARK: - Constants

  private static let cacheTTL: TimeInterval = 5 * 60  // 5 minutes
  private static let maxDepth = 20
  private static let maxSearchResults = 50

  /// Directories and files that are always excluded from the index.
  private static let hardExcludedNames: Set<String> = [
    ".git", "node_modules", ".build", "DerivedData", ".DS_Store",
    "__pycache__", ".pytest_cache", ".mypy_cache", "venv", ".venv",
    ".tox", "dist", "build", ".next", ".nuxt", "coverage"
  ]

  /// Hidden files (starting with `.`) that are still useful to index.
  private static let allowedHiddenNames: Set<String> = [
    ".env", ".gitignore", ".eslintrc", ".prettierrc",
    ".swiftlint.yml", ".editorconfig", ".nvmrc"
  ]

  // MARK: - Cache

  private struct CacheEntry {
    let nodes: [FileTreeNode]
    let date: Date
  }

  private var cache: [String: CacheEntry] = [:]

  // MARK: - Initialization

  public init() {}

  // MARK: - Public API

  /// Returns the cached file tree for `projectPath`, or scans it fresh if the cache is stale.
  public func index(projectPath: String) async -> [FileTreeNode] {
    if let entry = cache[projectPath], !isCacheStale(entry.date) {
      return entry.nodes
    }
    let nodes = await scanDirectory(at: projectPath)
    cache[projectPath] = CacheEntry(nodes: nodes, date: Date())
    return nodes
  }

  /// Fuzzy-searches files in `projectPath`.
  /// - Empty query returns the first 50 files (unsorted).
  /// - Non-empty query scores each file and returns up to 50 results sorted by score descending.
  public func search(query: String, in projectPath: String) async -> [FileSearchResult] {
    let tree = await index(projectPath: projectPath)
    let allFiles = flattenFiles(tree, projectPath: projectPath)

    guard !query.isEmpty else {
      return Array(allFiles.prefix(Self.maxSearchResults))
    }

    let q = query.lowercased()

    var scored: [(result: FileSearchResult, score: Int)] = []
    for file in allFiles {
      let nameScore = SearchScoring.score(query: q, against: file.name.lowercased()).map { $0.score * 2 }
      let pathScore = SearchScoring.score(query: q, against: file.relativePath.lowercased()).map { $0.score }
      let best = max(nameScore ?? 0, pathScore ?? 0)
      if best > 0 {
        scored.append((result: file, score: best))
      }
    }

    scored.sort { $0.score > $1.score }
    return scored.prefix(Self.maxSearchResults).map { $0.result }
  }

  /// Removes the cache entry for `projectPath`.
  public func invalidate(projectPath: String) {
    cache.removeValue(forKey: projectPath)
  }

  /// Reads a file at `path` as a UTF-8 string.
  public func readFile(at path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
  }

  /// Writes `content` to the file at `path` atomically, then invalidates any matching project cache.
  public func writeFile(at path: String, content: String) throws {
    let url = URL(fileURLWithPath: path)
    try content.write(to: url, atomically: true, encoding: .utf8)
    // Invalidate the cache for any project whose path is a prefix of the written file
    for key in cache.keys where path.hasPrefix(key) {
      cache.removeValue(forKey: key)
    }
  }

  // MARK: - Cache Helpers

  private func isCacheStale(_ date: Date) -> Bool {
    Date().timeIntervalSince(date) > Self.cacheTTL
  }

  // MARK: - Scanning

  private func scanDirectory(at path: String) async -> [FileTreeNode] {
    await Task.detached(priority: .utility) {
      FileIndexService.scanDirectorySync(at: path, relativeTo: path, depth: 0)
    }.value
  }

  private static func scanDirectorySync(
    at path: String,
    relativeTo rootPath: String,
    depth: Int
  ) -> [FileTreeNode] {
    guard depth < maxDepth else { return [] }

    let fm = FileManager.default

    guard let rawEntries = try? fm.contentsOfDirectory(atPath: path) else {
      return []
    }

    // Parse .gitignore in this directory
    let gitignorePatterns = parseGitignore(at: path)

    var nodes: [FileTreeNode] = []

    for name in rawEntries {
      // Hard-exclude check
      if hardExcludedNames.contains(name) { continue }

      // Hidden file filtering
      if name.hasPrefix(".") {
        let allowed = allowedHiddenNames.contains(name)
          || name.hasSuffix(".yaml")
          || name.hasSuffix(".json")
        if !allowed { continue }
      }

      let fullPath = (path as NSString).appendingPathComponent(name)
      let relativePath = fullPath.hasPrefix(rootPath + "/")
        ? String(fullPath.dropFirst(rootPath.count + 1))
        : name

      // Gitignore check
      if isIgnored(name: name, relativePath: relativePath, patterns: gitignorePatterns) {
        continue
      }

      var isDir: ObjCBool = false
      fm.fileExists(atPath: fullPath, isDirectory: &isDir)

      if isDir.boolValue {
        let children = scanDirectorySync(at: fullPath, relativeTo: rootPath, depth: depth + 1)
        let node = FileTreeNode(
          id: fullPath,
          name: name,
          path: fullPath,
          isDirectory: true,
          children: children
        )
        nodes.append(node)
      } else {
        let node = FileTreeNode(
          id: fullPath,
          name: name,
          path: fullPath,
          isDirectory: false
        )
        nodes.append(node)
      }
    }

    // Sort: directories first (alphabetical), then files (alphabetical)
    nodes.sort { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory {
        return lhs.isDirectory
      }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    return nodes
  }

  // MARK: - Gitignore Parsing

  private static func parseGitignore(at directoryPath: String) -> [String] {
    let gitignorePath = (directoryPath as NSString).appendingPathComponent(".gitignore")
    guard let content = try? String(contentsOfFile: gitignorePath, encoding: .utf8) else {
      return []
    }
    return content
      .components(separatedBy: .newlines)
      .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  private static func isIgnored(name: String, relativePath: String, patterns: [String]) -> Bool {
    for pattern in patterns {
      var p = pattern
      // Strip leading slash (anchored to repo root — treat as simple name match here)
      if p.hasPrefix("/") { p = String(p.dropFirst()) }
      if matchesPattern(p, name: name, relativePath: relativePath) {
        return true
      }
    }
    return false
  }

  /// Simple glob matching supporting `*` wildcard.
  private static func matchesPattern(_ pattern: String, name: String, relativePath: String) -> Bool {
    // If pattern contains `/`, match against relative path; otherwise against name only
    let target = pattern.contains("/") ? relativePath : name
    return globMatch(pattern: pattern, string: target)
  }

  /// Lightweight glob match: supports `*` as a wildcard matching any sequence of non-slash chars.
  private static func globMatch(pattern: String, string: String) -> Bool {
    var p = pattern[pattern.startIndex...]
    var s = string[string.startIndex...]

    while !p.isEmpty {
      if p.first == "*" {
        p = p.dropFirst()
        if p.isEmpty { return true }
        // Try matching the remainder from every position in s
        while !s.isEmpty {
          if globMatch(pattern: String(p), string: String(s)) { return true }
          s = s.dropFirst()
        }
        return false
      } else if s.isEmpty {
        return false
      } else if p.first == s.first {
        p = p.dropFirst()
        s = s.dropFirst()
      } else {
        return false
      }
    }

    return s.isEmpty
  }

  // MARK: - Search Helpers

  /// Recursively flattens all leaf file nodes into `FileSearchResult` objects.
  private func flattenFiles(_ nodes: [FileTreeNode], projectPath: String) -> [FileSearchResult] {
    var results: [FileSearchResult] = []
    flattenFilesInto(&results, nodes: nodes, projectPath: projectPath)
    return results
  }

  private func flattenFilesInto(
    _ results: inout [FileSearchResult],
    nodes: [FileTreeNode],
    projectPath: String
  ) {
    for node in nodes {
      if node.isDirectory {
        if let children = node.children {
          flattenFilesInto(&results, nodes: children, projectPath: projectPath)
        }
      } else {
        let relativePath = node.path.hasPrefix(projectPath + "/")
          ? String(node.path.dropFirst(projectPath.count + 1))
          : node.name
        results.append(FileSearchResult(
          id: node.path,
          name: node.name,
          relativePath: relativePath,
          absolutePath: node.path,
          score: 0
        ))
      }
    }
  }
}
