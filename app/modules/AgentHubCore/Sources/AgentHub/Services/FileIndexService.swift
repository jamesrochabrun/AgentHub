//
//  FileIndexService.swift
//  AgentHub
//
//  Actor-based file tree service with gitignore support and Spotlight-backed search.
//

import AgentHubFileSearch
import Foundation

// MARK: - FileIndexService

public enum FileSearchIndexStatus: Sendable, Equatable {
  case idle
  case building
  case ready
}

public enum FileSearchResultSource: Sendable, Equatable {
  case spotlight
  case localIndex
}

public struct FileSearchDiagnostics: Sendable, Equatable {
  public let results: [FileSearchResult]
  public let source: FileSearchResultSource
  public let spotlightCandidateCount: Int
  public let spotlightElapsedSeconds: TimeInterval
  public let localIndexStatusBeforeFallback: FileSearchIndexStatus
  public let localIndexedFileCount: Int
  public let localIndexElapsedSeconds: TimeInterval?

  public init(
    results: [FileSearchResult],
    source: FileSearchResultSource,
    spotlightCandidateCount: Int,
    spotlightElapsedSeconds: TimeInterval,
    localIndexStatusBeforeFallback: FileSearchIndexStatus,
    localIndexedFileCount: Int,
    localIndexElapsedSeconds: TimeInterval?
  ) {
    self.results = results
    self.source = source
    self.spotlightCandidateCount = spotlightCandidateCount
    self.spotlightElapsedSeconds = spotlightElapsedSeconds
    self.localIndexStatusBeforeFallback = localIndexStatusBeforeFallback
    self.localIndexedFileCount = localIndexedFileCount
    self.localIndexElapsedSeconds = localIndexElapsedSeconds
  }
}

enum ProjectFileEnumerationKind: Sendable, Equatable {
  case gitRepository
  case gitWorktree
}

struct ProjectFileEnumeratorFile: Sendable, Equatable {
  let relativePath: String
}

enum ProjectFileEnumerationResult: Sendable {
  case files([ProjectFileEnumeratorFile], kind: ProjectFileEnumerationKind)
  case notGitProject
  case failed
}

protocol ProjectFileEnumerating: Sendable {
  func gitProjectKind(at projectPath: String) -> ProjectFileEnumerationKind?
  func enumerateFiles(in projectPath: String) async -> ProjectFileEnumerationResult
}

struct GitProjectFileEnumerator: ProjectFileEnumerating {
  private struct GitCommandResult: Sendable {
    let stdout: Data
    let exitCode: Int32
    let timedOut: Bool
  }

  private static let commandTimeout: TimeInterval = 3

  func gitProjectKind(at projectPath: String) -> ProjectFileEnumerationKind? {
    guard let gitPath = Self.nearestGitPath(containing: projectPath) else {
      return nil
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
      return nil
    }

    return isDirectory.boolValue ? .gitRepository : .gitWorktree
  }

  func enumerateFiles(in projectPath: String) async -> ProjectFileEnumerationResult {
    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    let knownKind = gitProjectKind(at: resolvedProjectPath)
    guard let result = await runGitLSFiles(in: resolvedProjectPath) else {
      return knownKind == nil ? .notGitProject : .failed
    }

    guard !result.timedOut, result.exitCode == 0 else {
      return knownKind == nil ? .notGitProject : .failed
    }

    let files = Self.parseGitLSFilesOutput(result.stdout)
    return .files(files, kind: knownKind ?? .gitRepository)
  }

  private func runGitLSFiles(in projectPath: String) async -> GitCommandResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = [
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
      "--",
      "."
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    process.environment = environment

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    var outputData: Data?
    let readGroup = DispatchGroup()

    do {
      try process.run()
      try? inputPipe.fileHandleForWriting.close()
    } catch {
      return nil
    }

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      outputData = try? outputPipe.fileHandleForReading.readToEnd()
      readGroup.leave()
    }

    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      _ = try? errorPipe.fileHandleForReading.readToEnd()
      readGroup.leave()
    }

    let timedOut = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          DispatchQueue.global(qos: .utility).async {
            readGroup.wait()
            process.waitUntilExit()
            continuation.resume(returning: false)
          }
        }
      }

      group.addTask {
        do {
          try await Task.sleep(for: .seconds(Self.commandTimeout))
          if process.isRunning {
            process.terminate()
          }
          return true
        } catch {
          return false
        }
      }

      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }

    return GitCommandResult(
      stdout: outputData ?? Data(),
      exitCode: process.terminationStatus,
      timedOut: timedOut
    )
  }

  private static func parseGitLSFilesOutput(_ data: Data) -> [ProjectFileEnumeratorFile] {
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    var seen = Set<String>()
    return output
      .split(separator: "\0")
      .compactMap { rawPath -> ProjectFileEnumeratorFile? in
        let path = String(rawPath)
        guard isSafeRelativePath(path), seen.insert(path).inserted else {
          return nil
        }
        return ProjectFileEnumeratorFile(relativePath: path)
      }
  }

  private static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/") else { return false }
    return path.split(separator: "/").allSatisfy { component in
      component != "." && component != ".."
    }
  }

  private static func nearestGitPath(containing path: String) -> String? {
    var currentPath = resolvedURL(for: path).path
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: currentPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
      currentPath = (currentPath as NSString).deletingLastPathComponent
    }

    while !currentPath.isEmpty {
      let gitPath = (currentPath as NSString).appendingPathComponent(".git")
      if FileManager.default.fileExists(atPath: gitPath) {
        return gitPath
      }

      let parentPath = (currentPath as NSString).deletingLastPathComponent
      if parentPath == currentPath {
        return nil
      }
      currentPath = parentPath
    }

    return nil
  }

  private static func resolvedURL(for path: String) -> URL {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
  }
}

/// Scans project directories, respects .gitignore, caches tree nodes, and provides project file search.
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
  private let projectFileSearchService: any ProjectFileSearchServiceProtocol
  private let projectFileEnumerator: any ProjectFileEnumerating

  // MARK: - Initialization

  public init() {
    self.projectFileSearchService = SpotlightProjectFileSearchService.shared
    self.projectFileEnumerator = GitProjectFileEnumerator()
  }

  init(
    projectFileSearchService: any ProjectFileSearchServiceProtocol,
    projectFileEnumerator: any ProjectFileEnumerating = GitProjectFileEnumerator()
  ) {
    self.projectFileSearchService = projectFileSearchService
    self.projectFileEnumerator = projectFileEnumerator
  }

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
    // Spotlight is queried directly for Cmd+P. Keep the legacy fallback warm only
    // for callers that explicitly request preloading.
    _ = await searchIndex(projectPath: Self.resolvedURL(for: projectPath).path)
  }

  public func searchIndexStatus(projectPath: String) async -> FileSearchIndexStatus {
    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    return searchIndexStatus(resolvedProjectPath: resolvedProjectPath)
  }

  /// Searches files using Spotlight first, then falls back to a local index if
  /// Spotlight has no usable results for the project. Git worktrees use the local
  /// Git-backed index first because Spotlight often lags or misses them entirely.
  /// Ranking uses a strict 3-tier approach:
  /// 1. Filename starts with query → highest score
  /// 2. Filename contains query as substring → high score
  /// 3. Path contains query as substring → medium score
  /// All matching is case-insensitive substring, no fuzzy.
  public func search(query: String, in projectPath: String) async -> [FileSearchResult] {
    await searchWithDiagnostics(query: query, in: projectPath).results
  }

  public func searchWithDiagnostics(query: String, in projectPath: String) async -> FileSearchDiagnostics {
    guard !query.isEmpty, query.count < 200 else {
      return FileSearchDiagnostics(
        results: [],
        source: .localIndex,
        spotlightCandidateCount: 0,
        spotlightElapsedSeconds: 0,
        localIndexStatusBeforeFallback: .idle,
        localIndexedFileCount: 0,
        localIndexElapsedSeconds: nil
      )
    }

    let resolvedProjectPath = Self.resolvedURL(for: projectPath).path
    let localStatusBeforeFallback = searchIndexStatus(resolvedProjectPath: resolvedProjectPath)
    let usesWorktreeLocalIndexFirst = projectFileEnumerator.gitProjectKind(at: resolvedProjectPath) == .gitWorktree

    var spotlightCandidateCount = 0
    var spotlightElapsedSeconds: TimeInterval = 0
    if !usesWorktreeLocalIndexFirst {
      let spotlightResponse = await projectFileSearchService.searchWithDiagnostics(
        query: query,
        in: resolvedProjectPath,
        limit: Self.maxSearchResults * 10
      )
      spotlightCandidateCount = spotlightResponse.candidateCount
      spotlightElapsedSeconds = spotlightResponse.elapsedSeconds

      let filteredSpotlightResults = spotlightResponse.results
        .compactMap { spotlightResult -> FileSearchResult? in
          let absolutePath = Self.resolvedURL(for: spotlightResult.absolutePath).path
          guard Self.shouldIncludeSearchResult(at: absolutePath, rootPath: resolvedProjectPath),
                let relativePath = Self.relativePathIfContained(absolutePath, within: resolvedProjectPath) else {
            return nil
          }
          let name = URL(fileURLWithPath: absolutePath).lastPathComponent

          return FileSearchResult(
            id: absolutePath,
            name: name,
            relativePath: relativePath,
            absolutePath: absolutePath,
            score: spotlightResult.score
          )
        }
        .sortedBySearchScore()

      if !filteredSpotlightResults.isEmpty {
        return FileSearchDiagnostics(
          results: Array(filteredSpotlightResults.prefix(Self.maxSearchResults)),
          source: .spotlight,
          spotlightCandidateCount: spotlightCandidateCount,
          spotlightElapsedSeconds: spotlightElapsedSeconds,
          localIndexStatusBeforeFallback: localStatusBeforeFallback,
          localIndexedFileCount: searchCache[resolvedProjectPath]?.files.count ?? 0,
          localIndexElapsedSeconds: nil
        )
      }
    }

    let localIndexStart = Date()
    let allFiles = await searchIndex(projectPath: resolvedProjectPath)
    let localIndexElapsed = Date().timeIntervalSince(localIndexStart)
    let q = query.lowercased()

    let scored = Self.rankIndexedFiles(allFiles, query: q)
    return FileSearchDiagnostics(
      results: Array(scored.prefix(Self.maxSearchResults)),
      source: .localIndex,
      spotlightCandidateCount: spotlightCandidateCount,
      spotlightElapsedSeconds: spotlightElapsedSeconds,
      localIndexStatusBeforeFallback: localStatusBeforeFallback,
      localIndexedFileCount: allFiles.count,
      localIndexElapsedSeconds: localIndexElapsed
    )
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

  private func searchIndexStatus(resolvedProjectPath: String) -> FileSearchIndexStatus {
    if searchBuildTasks[resolvedProjectPath] != nil {
      return .building
    }

    if let entry = searchCache[resolvedProjectPath], !isCacheStale(entry.date) {
      return .ready
    }

    return .idle
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
    let projectFileEnumerator = projectFileEnumerator
    return Task.detached(priority: .utility) {
      let files = await FileIndexService.buildSearchIndex(
        projectPath: projectPath,
        projectFileEnumerator: projectFileEnumerator
      )
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

  private static func buildSearchIndex(
    projectPath: String,
    projectFileEnumerator: any ProjectFileEnumerating
  ) async -> [IndexedFile] {
    switch await projectFileEnumerator.enumerateFiles(in: projectPath) {
    case .files(let files, _):
      return buildSearchIndexFromGitFiles(files, rootPath: projectPath)
    case .notGitProject:
      return buildSearchIndexSync(projectPath: projectPath)
    case .failed:
      return []
    }
  }

  private static func buildSearchIndexFromGitFiles(
    _ files: [ProjectFileEnumeratorFile],
    rootPath: String
  ) -> [IndexedFile] {
    files.compactMap { file in
      let absolutePath = (rootPath as NSString).appendingPathComponent(file.relativePath)
      guard shouldIncludeSearchResult(at: absolutePath, rootPath: rootPath),
            let relativePath = relativePathIfContained(absolutePath, within: rootPath) else {
        return nil
      }

      return IndexedFile(
        name: URL(fileURLWithPath: absolutePath).lastPathComponent,
        relativePath: relativePath,
        absolutePath: absolutePath
      )
    }
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
    let relativePath = projectRelativePath(for: entry.path, relativeTo: rootPath)
    guard pathComponentsAreSearchable(relativePath) else { return false }
    return !isIgnored(relativePath: relativePath, isDirectory: entry.isDirectory, rules: rules)
  }

  private static func pathComponentsAreSearchable(_ relativePath: String) -> Bool {
    relativePath
      .split(separator: "/")
      .allSatisfy { component in
        let name = String(component)
        if hardExcludedNames.contains(name) {
          return false
        }

        if name.hasPrefix(".") && !allowedHiddenNames.contains(name) {
          return false
        }

        return true
      }
  }

  private static func shouldIncludeSearchResult(at path: String, rootPath: String) -> Bool {
    let resolvedRootPath = resolvedURL(for: rootPath).path
    let resolvedPath = resolvedURL(for: path).path
    guard isPath(resolvedPath, within: resolvedRootPath),
          resolvedPath != resolvedRootPath else {
      return false
    }

    let url = URL(fileURLWithPath: resolvedPath)
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
          values.isDirectory != true,
          values.isSymbolicLink != true else {
      return false
    }

    let directoryPath = (resolvedPath as NSString).deletingLastPathComponent
    let rules = ignoreRules(forDirectoryAt: directoryPath, rootPath: resolvedRootPath)
    return shouldIncludeEntry(
      DirectoryEntry(
        name: url.lastPathComponent,
        path: resolvedPath,
        isDirectory: false
      ),
      rootPath: resolvedRootPath,
      rules: rules
    )
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

  private static func rankIndexedFiles(_ files: [IndexedFile], query: String) -> [FileSearchResult] {
    var scored: [FileSearchResult] = []
    scored.reserveCapacity(min(files.count, maxSearchResults))

    for file in files {
      let nameLower = file.name.lowercased()
      let nameNoExt = (file.name as NSString).deletingPathExtension.lowercased()
      let pathLower = file.relativePath.lowercased()

      var score = 0
      if nameNoExt == query {
        score = 5000
      } else if nameNoExt.hasPrefix(query) {
        score = 4000 + (100 - min(nameLower.count, 100))
      } else if nameLower.hasPrefix(query) {
        score = 3500 + (100 - min(nameLower.count, 100))
      } else if nameLower.contains(query), let nameRange = nameLower.range(of: query) {
        let position = nameRange.lowerBound.utf16Offset(in: nameLower)
        score = 2000 + (200 - position) + (100 - min(nameLower.count, 100))
      } else if pathLower.contains(query), let pathRange = pathLower.range(of: query) {
        let position = pathRange.lowerBound.utf16Offset(in: pathLower)
        score = 1000 + (500 - min(position, 500))
      }

      guard score > 0 else { continue }
      scored.append(FileSearchResult(
        id: file.absolutePath,
        name: file.name,
        relativePath: file.relativePath,
        absolutePath: file.absolutePath,
        score: score
      ))
    }

    return scored.sortedBySearchScore()
  }

}

private extension Array where Element == FileSearchResult {
  func sortedBySearchScore() -> [FileSearchResult] {
    sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      let nameOrder = $0.name.localizedStandardCompare($1.name)
      if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
      return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
  }
}
