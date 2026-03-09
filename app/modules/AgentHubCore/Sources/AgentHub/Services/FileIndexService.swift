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

  /// Hidden files/dirs (starting with `.`) that are still useful to index.
  private static let allowedHiddenNames: Set<String> = [
    ".env", ".env.local", ".env.development", ".env.production", ".env.example",
    ".gitignore", ".gitmodules", ".gitattributes",
    ".eslintrc", ".eslintrc.js", ".eslintrc.json", ".eslintrc.yml",
    ".prettierrc", ".prettierrc.js", ".prettierrc.json", ".prettierrc.yml",
    ".swiftlint.yml", ".swiftformat",
    ".editorconfig", ".nvmrc", ".node-version", ".ruby-version", ".python-version",
    ".npmrc", ".yarnrc", ".yarnrc.yml",
    ".babelrc", ".babelrc.json",
    ".dockerignore", ".docker",
    ".github", ".vscode", ".cursor",
    ".claude", ".clauderc",
    ".env.test", ".env.staging"
  ]

  // MARK: - Cache

  private struct CacheEntry {
    let nodes: [FileTreeNode]
    let date: Date
  }

  private var cache: [String: CacheEntry] = [:]
  private var recentPaths: [String] = []
  private static let maxRecentFiles = 20

  // MARK: - Initialization

  public init() {}

  // MARK: - Public API

  /// Records a file as recently opened (most recent first, deduped).
  public func addToRecent(_ path: String) {
    recentPaths.removeAll { $0 == path }
    recentPaths.insert(path, at: 0)
    if recentPaths.count > Self.maxRecentFiles {
      recentPaths = Array(recentPaths.prefix(Self.maxRecentFiles))
    }
  }

  /// Returns recently opened files that belong to `projectPath`, as `FileSearchResult` objects.
  public func recentFiles(in projectPath: String) -> [FileSearchResult] {
    recentPaths
      .filter { $0.hasPrefix(projectPath + "/") || $0.hasPrefix(projectPath) }
      .map { path in
        let name = URL(fileURLWithPath: path).lastPathComponent
        let relativePath = path.hasPrefix(projectPath + "/")
          ? String(path.dropFirst(projectPath.count + 1))
          : name
        return FileSearchResult(
          id: path,
          name: name,
          relativePath: relativePath,
          absolutePath: path,
          score: 0
        )
      }
  }

  /// Returns the cached file tree for `projectPath`, or scans it fresh if the cache is stale.
  public func index(projectPath: String) async -> [FileTreeNode] {
    if let entry = cache[projectPath], !isCacheStale(entry.date) {
      return entry.nodes
    }
    let nodes = await scanDirectory(at: projectPath)
    cache[projectPath] = CacheEntry(nodes: nodes, date: Date())
    return nodes
  }

  /// Searches files using a strict 3-tier approach:
  /// 1. Filename starts with query → highest score
  /// 2. Filename contains query as substring → high score
  /// 3. Path contains query as substring → medium score
  /// All matching is case-insensitive substring, no fuzzy.
  public func search(query: String, in projectPath: String) async -> [FileSearchResult] {
    guard !query.isEmpty else { return [] }
    let nodes = await index(projectPath: projectPath)
    let allFiles = flattenFiles(nodes, projectPath: projectPath)
    let q = query.lowercased()

    var scored: [FileSearchResult] = []
    for file in allFiles {
      let nameLower = file.name.lowercased()
      let nameNoExt = (file.name as NSString).deletingPathExtension.lowercased()
      let pathLower = file.relativePath.lowercased()

      var score = 0
      if nameNoExt == q {
        // Exact match (without extension)
        score = 5000
      } else if nameNoExt.hasPrefix(q) {
        // Filename starts with query (without extension)
        score = 4000 + (100 - min(nameLower.count, 100))
      } else if nameLower.hasPrefix(q) {
        // Filename starts with query (with extension)
        score = 3500 + (100 - min(nameLower.count, 100))
      } else if nameLower.contains(q) {
        // Filename contains query
        let pos = nameLower.range(of: q)!.lowerBound.utf16Offset(in: nameLower)
        score = 2000 + (200 - pos) + (100 - min(nameLower.count, 100))
      } else if pathLower.contains(q) {
        // Path contains query
        let pos = pathLower.range(of: q)!.lowerBound.utf16Offset(in: pathLower)
        score = 1000 + (500 - min(pos, 500))
      }

      guard score > 0 else { continue }
      scored.append(FileSearchResult(
        id: file.id, name: file.name, relativePath: file.relativePath,
        absolutePath: file.absolutePath, score: score
      ))
    }

    scored.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      return $0.name < $1.name
    }
    return Array(scored.prefix(Self.maxSearchResults))
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
      let rootPatterns = FileIndexService.parseGitignore(at: path)
      return FileIndexService.scanDirectorySync(
        at: path, relativeTo: path, depth: 0, inheritedPatterns: rootPatterns
      )
    }.value
  }

  private static func scanDirectorySync(
    at path: String,
    relativeTo rootPath: String,
    depth: Int,
    inheritedPatterns: [String]
  ) -> [FileTreeNode] {
    guard depth < maxDepth else { return [] }

    let fm = FileManager.default

    guard let rawEntries = try? fm.contentsOfDirectory(atPath: path) else {
      return []
    }

    // Merge inherited patterns with this directory's own .gitignore
    let localPatterns = depth == 0 ? [] : parseGitignore(at: path)
    let allPatterns = inheritedPatterns + localPatterns

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
      if isIgnored(name: name, relativePath: relativePath, patterns: allPatterns) {
        continue
      }

      var isDir: ObjCBool = false
      fm.fileExists(atPath: fullPath, isDirectory: &isDir)

      if isDir.boolValue {
        let children = scanDirectorySync(
          at: fullPath, relativeTo: rootPath, depth: depth + 1,
          inheritedPatterns: allPatterns
        )
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
