//
//  FileIndexService.swift
//  AgentHub
//
//  Actor-based file index service with gitignore support and fuzzy search.
//

import Foundation

// MARK: - FileIndexService

public enum FileSearchIndexStatus: Sendable {
  case idle
  case building
  case ready
}

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
  /// Keep this list intentionally narrow to avoid surfacing secret-bearing dotfiles.
  private static let allowedHiddenNames: Set<String> = [
    ".gitignore", ".gitmodules", ".gitattributes",
    ".eslintrc", ".eslintrc.js", ".eslintrc.json", ".eslintrc.yml",
    ".prettierrc", ".prettierrc.js", ".prettierrc.json", ".prettierrc.yml",
    ".swiftlint.yml", ".swiftformat",
    ".editorconfig", ".nvmrc", ".node-version", ".ruby-version", ".python-version",
    ".babelrc", ".babelrc.json",
    ".dockerignore", ".docker",
    ".github", ".vscode", ".cursor"
  ]

  private struct IgnoreRule {
    let basePath: String
    let pattern: String
    let isNegated: Bool
    let directoryOnly: Bool
    let matchesRelativePath: Bool
  }

  // MARK: - Cache

  private struct CacheEntry {
    let nodes: [FileTreeNode]
    let date: Date
  }

  private struct IndexedFile: Sendable {
    let name: String
    let relativePath: String
    let absolutePath: String
  }

  private struct SearchCacheEntry: Sendable {
    let files: [IndexedFile]
    let date: Date
  }

  private struct DirectoryEntry: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
  }

  private var directoryCache: [String: CacheEntry] = [:]
  private var directoryLoadTasks: [String: Task<[FileTreeNode], Never>] = [:]
  private var searchCache: [String: SearchCacheEntry] = [:]
  private var searchBuildTasks: [String: Task<SearchCacheEntry, Never>] = [:]
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
      .compactMap { path in
        guard let relativePath = Self.relativePathIfContained(path, within: projectPath) else {
          return nil
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return FileSearchResult(
          id: path,
          name: name,
          relativePath: relativePath,
          absolutePath: path,
          score: 0
        )
      }
  }

  /// Legacy entry point kept for compatibility. Returns the lazily loaded root nodes.
  public func index(projectPath: String) async -> [FileTreeNode] {
    await rootNodes(projectPath: projectPath)
  }

  public func rootNodes(projectPath: String) async -> [FileTreeNode] {
    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    return await cachedDirectoryNodes(at: resolvedProjectPath, rootPath: resolvedProjectPath)
  }

  public func children(of directoryPath: String, in projectPath: String) async -> [FileTreeNode] {
    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    let resolvedDirectoryPath = Self.resolvedURL(for: directoryPath).path
    guard Self.isPath(resolvedDirectoryPath, within: resolvedProjectPath) else {
      return []
    }
    return await cachedDirectoryNodes(at: resolvedDirectoryPath, rootPath: resolvedProjectPath)
  }

  public func prepareSearchIndex(projectPath: String) async {
    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    guard searchCache[resolvedProjectPath].map({ !isCacheStale($0.date) }) != true else { return }
    if searchBuildTasks[resolvedProjectPath] == nil {
      searchBuildTasks[resolvedProjectPath] = makeSearchBuildTask(projectPath: resolvedProjectPath)
    }
  }

  public func searchIndexStatus(projectPath: String) async -> FileSearchIndexStatus {
    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    if let entry = searchCache[resolvedProjectPath], !isCacheStale(entry.date) {
      return .ready
    }
    if searchBuildTasks[resolvedProjectPath] != nil {
      return .building
    }
    return .idle
  }

  /// Searches files using a strict 3-tier approach:
  /// 1. Filename starts with query → highest score
  /// 2. Filename contains query as substring → high score
  /// 3. Path contains query as substring → medium score
  /// All matching is case-insensitive substring, no fuzzy.
  public func search(query: String, in projectPath: String) async -> [FileSearchResult] {
    guard !query.isEmpty, query.count < 200 else { return [] }
    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    let allFiles = await searchIndex(projectPath: resolvedProjectPath)
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
      } else if nameLower.contains(q), let nameRange = nameLower.range(of: q) {
        // Filename contains query
        let pos = nameRange.lowerBound.utf16Offset(in: nameLower)
        score = 2000 + (200 - pos) + (100 - min(nameLower.count, 100))
      } else if pathLower.contains(q), let pathRange = pathLower.range(of: q) {
        // Path contains query
        let pos = pathRange.lowerBound.utf16Offset(in: pathLower)
        score = 1000 + (500 - min(pos, 500))
      }

      guard score > 0 else { continue }
      scored.append(FileSearchResult(
        id: file.absolutePath, name: file.name, relativePath: file.relativePath,
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
    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    directoryCache.keys
      .filter { Self.isPath($0, within: resolvedProjectPath) }
      .forEach { directoryCache.removeValue(forKey: $0) }
    directoryLoadTasks.keys
      .filter { Self.isPath($0, within: resolvedProjectPath) }
      .forEach { path in
        directoryLoadTasks[path]?.cancel()
        directoryLoadTasks.removeValue(forKey: path)
      }
    searchCache.removeValue(forKey: resolvedProjectPath)
    searchBuildTasks[resolvedProjectPath]?.cancel()
    searchBuildTasks.removeValue(forKey: resolvedProjectPath)
  }

  /// Reads a file at `path` as a UTF-8 string.
  /// `projectPath` is required so the read is validated to stay within the project root.
  public func readFile(at path: String, projectPath: String) throws -> String {
    let validatedURL = try validatePath(path, within: projectPath, forWrite: false)
    return try String(contentsOf: validatedURL, encoding: .utf8)
  }

  /// Writes `content` to the file at `path` atomically, then invalidates any matching project cache.
  /// `projectPath` is required so the write is validated to stay within the project root.
  public func writeFile(at path: String, content: String, projectPath: String) throws {
    let validatedURL = try validatePath(path, within: projectPath, forWrite: true)
    let didExist = FileManager.default.fileExists(atPath: validatedURL.path)
    try content.write(to: validatedURL, atomically: true, encoding: .utf8)
    if !didExist {
      invalidate(projectPath: projectPath)
    }
  }

  // MARK: - Path Validation

  /// Throws if `path` does not reside inside `projectRoot` after resolving symlinks.
  private func validatePath(_ path: String, within projectRoot: String, forWrite: Bool) throws -> URL {
    let resolvedRootURL = Self.resolvedURL(for: projectRoot)
    let candidateURL = URL(fileURLWithPath: path).standardizedFileURL

    let resolvedCandidateURL: URL
    if forWrite {
      let resolvedParentURL = Self.resolvedURL(for: candidateURL.deletingLastPathComponent().path)
      resolvedCandidateURL = resolvedParentURL
        .appendingPathComponent(candidateURL.lastPathComponent)
        .standardizedFileURL
    } else {
      resolvedCandidateURL = Self.resolvedURL(for: candidateURL.path)
    }

    guard Self.isPath(resolvedCandidateURL.path, within: resolvedRootURL.path) else {
      throw CocoaError(.fileReadNoPermission, userInfo: [
        NSLocalizedDescriptionKey: "Access denied: path is outside the project directory."
      ])
    }

    return resolvedCandidateURL
  }

  // MARK: - Cache Helpers

  private func isCacheStale(_ date: Date) -> Bool {
    Date().timeIntervalSince(date) > Self.cacheTTL
  }

  // MARK: - Scanning

  private func cachedDirectoryNodes(at directoryPath: String, rootPath: String) async -> [FileTreeNode] {
    if let entry = directoryCache[directoryPath], !isCacheStale(entry.date) {
      return entry.nodes
    }
    if let task = directoryLoadTasks[directoryPath] {
      return await task.value
    }

    let task = Task.detached(priority: .utility) {
      let rules = FileIndexService.ignoreRules(forDirectoryAt: directoryPath, rootPath: rootPath)
      return FileIndexService.scanDirectoryContentsSync(
        at: directoryPath,
        rootPath: rootPath,
        rules: rules
      )
    }
    directoryLoadTasks[directoryPath] = task

    let nodes = await task.value
    directoryLoadTasks.removeValue(forKey: directoryPath)
    directoryCache[directoryPath] = CacheEntry(nodes: nodes, date: Date())
    return nodes
  }

  private func searchIndex(projectPath: String) async -> [IndexedFile] {
    if let entry = searchCache[projectPath], !isCacheStale(entry.date) {
      return entry.files
    }

    let task: Task<SearchCacheEntry, Never>
    if let existingTask = searchBuildTasks[projectPath] {
      task = existingTask
    } else {
      let newTask = makeSearchBuildTask(projectPath: projectPath)
      searchBuildTasks[projectPath] = newTask
      task = newTask
    }

    let entry = await task.value
    searchBuildTasks.removeValue(forKey: projectPath)
    searchCache[projectPath] = entry
    return entry.files
  }

  private func makeSearchBuildTask(projectPath: String) -> Task<SearchCacheEntry, Never> {
    Task.detached(priority: .utility) {
      let files = FileIndexService.buildSearchIndexSync(projectPath: projectPath)
      return SearchCacheEntry(files: files, date: Date())
    }
  }

  private static func scanDirectoryContentsSync(
    at path: String,
    rootPath: String,
    rules: [IgnoreRule]
  ) -> [FileTreeNode] {
    filteredDirectoryEntries(at: path, rootPath: rootPath, rules: rules).map { entry in
      FileTreeNode(
        id: entry.path,
        name: entry.name,
        path: entry.path,
        isDirectory: entry.isDirectory
      )
    }
  }

  private static func buildSearchIndexSync(projectPath: String) -> [IndexedFile] {
    var files: [IndexedFile] = []
    collectSearchEntriesSync(
      at: projectPath,
      rootPath: projectPath,
      depth: 0,
      inheritedRules: [],
      into: &files
    )
    return files
  }

  private static func collectSearchEntriesSync(
    at path: String,
    rootPath: String,
    depth: Int,
    inheritedRules: [IgnoreRule],
    into results: inout [IndexedFile]
  ) {
    guard depth < maxDepth else { return }

    let allRules = inheritedRules + parseGitignore(at: path, relativeTo: rootPath)
    let entries = filteredDirectoryEntries(at: path, rootPath: rootPath, rules: allRules)

    for entry in entries {
      if entry.isDirectory {
        collectSearchEntriesSync(
          at: entry.path,
          rootPath: rootPath,
          depth: depth + 1,
          inheritedRules: allRules,
          into: &results
        )
      } else {
        let relativePath = projectRelativePath(for: entry.path, relativeTo: rootPath)
        results.append(IndexedFile(
          name: entry.name,
          relativePath: relativePath,
          absolutePath: entry.path
        ))
      }
    }
  }

  private static func ignoreRules(forDirectoryAt directoryPath: String, rootPath: String) -> [IgnoreRule] {
    let resolvedRootPath = resolvedURL(for: rootPath).path
    let resolvedDirectoryPath = resolvedURL(for: directoryPath).path
    guard isPath(resolvedDirectoryPath, within: resolvedRootPath) else { return [] }

    var rules: [IgnoreRule] = []
    var currentPath = resolvedRootPath
    rules += parseGitignore(at: currentPath, relativeTo: resolvedRootPath)

    guard resolvedDirectoryPath != resolvedRootPath else { return rules }

    let relativePath = String(resolvedDirectoryPath.dropFirst(resolvedRootPath.count + 1))
    for component in relativePath.split(separator: "/") {
      currentPath = (currentPath as NSString).appendingPathComponent(String(component))
      rules += parseGitignore(at: currentPath, relativeTo: resolvedRootPath)
    }

    return rules
  }

  private static func filteredDirectoryEntries(
    at path: String,
    rootPath: String,
    rules: [IgnoreRule]
  ) -> [DirectoryEntry] {
    rawDirectoryEntries(at: path)
      .filter { entry in
        shouldIncludeEntry(entry, rootPath: rootPath, rules: rules)
      }
      .sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory {
          return lhs.isDirectory
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
  }

  private static func rawDirectoryEntries(at path: String) -> [DirectoryEntry] {
    let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    let directoryURL = URL(fileURLWithPath: path)

    guard let rawURLs = try? FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsPackageDescendants]
    ) else {
      return []
    }

    return rawURLs.compactMap { url in
      guard let values = try? url.resourceValues(forKeys: resourceKeys),
            values.isSymbolicLink != true else {
        return nil
      }

      return DirectoryEntry(
        name: url.lastPathComponent,
        path: url.path,
        isDirectory: values.isDirectory == true
      )
    }
  }

  private static func shouldIncludeEntry(
    _ entry: DirectoryEntry,
    rootPath: String,
    rules: [IgnoreRule]
  ) -> Bool {
    if hardExcludedNames.contains(entry.name) { return false }

    if entry.name.hasPrefix(".") && !allowedHiddenNames.contains(entry.name) {
      return false
    }

    let relativePath = projectRelativePath(for: entry.path, relativeTo: rootPath)
    return !isIgnored(relativePath: relativePath, isDirectory: entry.isDirectory, rules: rules)
  }

  // MARK: - Gitignore Parsing

  private static func parseGitignore(at directoryPath: String, relativeTo rootPath: String) -> [IgnoreRule] {
    let gitignorePath = (directoryPath as NSString).appendingPathComponent(".gitignore")
    guard let content = try? String(contentsOfFile: gitignorePath, encoding: .utf8) else {
      return []
    }

    let basePath = projectRelativePath(for: directoryPath, relativeTo: rootPath)
    return content
      .components(separatedBy: .newlines)
      .compactMap { parseIgnoreRule($0, basePath: basePath) }
  }

  private static func parseIgnoreRule(_ rawLine: String, basePath: String) -> IgnoreRule? {
    var line = rawLine.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

    var isNegated = false
    if line.hasPrefix("!") {
      isNegated = true
      line.removeFirst()
    }

    guard !line.isEmpty else { return nil }

    let isAnchored = line.hasPrefix("/")
    if isAnchored {
      line.removeFirst()
    }

    let directoryOnly = line.hasSuffix("/")
    if directoryOnly {
      line.removeLast()
    }

    guard !line.isEmpty else { return nil }

    return IgnoreRule(
      basePath: basePath,
      pattern: line,
      isNegated: isNegated,
      directoryOnly: directoryOnly,
      matchesRelativePath: isAnchored || line.contains("/")
    )
  }

  private static func isIgnored(relativePath: String, isDirectory: Bool, rules: [IgnoreRule]) -> Bool {
    var ignored = false

    for rule in rules {
      if matchesRule(rule, relativePath: relativePath, isDirectory: isDirectory) {
        ignored = !rule.isNegated
      }
    }

    return ignored
  }

  private static func matchesRule(_ rule: IgnoreRule, relativePath: String, isDirectory: Bool) -> Bool {
    guard let scopedPath = applyBasePath(rule.basePath, to: relativePath), !scopedPath.isEmpty else {
      return false
    }

    if rule.matchesRelativePath {
      if rule.directoryOnly {
        return scopedPath == rule.pattern || scopedPath.hasPrefix(rule.pattern + "/")
      }

      return globMatch(pattern: rule.pattern, string: scopedPath)
    }

    let components = scopedPath.split(separator: "/")
    for (index, component) in components.enumerated() {
      guard globMatch(pattern: rule.pattern, string: String(component)) else { continue }

      if !rule.directoryOnly {
        return true
      }

      let isLastComponent = index == components.count - 1
      if !isLastComponent || isDirectory {
        return true
      }
    }

    return false
  }

  private static func applyBasePath(_ basePath: String, to relativePath: String) -> String? {
    guard !basePath.isEmpty else { return relativePath }
    guard relativePath.hasPrefix(basePath + "/") else { return nil }
    return String(relativePath.dropFirst(basePath.count + 1))
  }

  /// Lightweight glob match for gitignore-style matching.
  /// Supports `*`, `**`, and `?`, with `*` not crossing path separators.
  private static func globMatch(pattern: String, string: String) -> Bool {
    let regexMetaCharacters = CharacterSet(charactersIn: "\\.^$+()[]{}|")
    var regex = "^"
    var index = pattern.startIndex

    while index < pattern.endIndex {
      let character = pattern[index]

      if character == "*" {
        let nextIndex = pattern.index(after: index)
        if nextIndex < pattern.endIndex, pattern[nextIndex] == "*" {
          regex += ".*"
          index = pattern.index(after: nextIndex)
        } else {
          regex += "[^/]*"
          index = nextIndex
        }
        continue
      }

      if character == "?" {
        regex += "[^/]"
        index = pattern.index(after: index)
        continue
      }

      if String(character).rangeOfCharacter(from: regexMetaCharacters) != nil {
        regex += "\\"
      }

      regex.append(character)
      index = pattern.index(after: index)
    }

    regex += "$"
    return string.range(of: regex, options: .regularExpression) != nil
  }

  private static func projectRelativePath(for path: String, relativeTo rootPath: String) -> String {
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    let standardizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    guard standardizedPath != standardizedRoot else { return "" }
    guard standardizedPath.hasPrefix(standardizedRoot + "/") else { return "" }
    return String(standardizedPath.dropFirst(standardizedRoot.count + 1))
  }

  private static func resolvedURL(for path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func isPath(_ path: String, within rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath + "/")
  }

  private static func relativePathIfContained(_ path: String, within projectPath: String) -> String? {
    let resolvedRootPath = resolvedURL(for: projectPath).path
    let resolvedPath = resolvedURL(for: path).path
    guard isPath(resolvedPath, within: resolvedRootPath), resolvedPath != resolvedRootPath else {
      return nil
    }

    return String(resolvedPath.dropFirst(resolvedRootPath.count + 1))
  }

  // MARK: - Search Helpers

}
