//
//  CLISessionMonitorService.swift
//  AgentHub
//
//  Created by Assistant on 1/9/26.
//

import Foundation
import Combine

// MARK: - CLISessionMonitorService

/// Service for monitoring active Claude Code CLI sessions from the ~/.claude folder
/// Uses path-based filtering to only show sessions from user-selected repositories
public actor CLISessionMonitorService {

  // MARK: - Configuration

  private let claudeDataPath: String
  private let metadataStore: SessionMetadataStore?

  // MARK: - Publishers

  // Using nonisolated(unsafe) since CurrentValueSubject is internally thread-safe
  private nonisolated(unsafe) let repositoriesSubject = CurrentValueSubject<[SelectedRepository], Never>([])
  public nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    repositoriesSubject.eraseToAnyPublisher()
  }

  // MARK: - State

  private var selectedRepositories: [SelectedRepository] = []

  // MARK: - Caches

  /// Cache of session metadata (branch + slug) keyed by session ID.
  /// Branch and slug don't change for existing sessions, so cache is always valid.
  private var sessionMetadataCache: [String: SessionMetadata] = [:]

  /// Byte offset into history.jsonl up to which we've already parsed.
  private var lastHistoryOffset: UInt64 = 0
  /// Accumulated per-session history summaries from previous incremental parses.
  private var cachedHistorySummaries: [String: HistorySessionSummary] = [:]

  /// Cache of worktree detection results keyed by repository path.
  private var worktreeCache: [String: [WorktreeBranch]] = [:]

  // MARK: - Initialization

  public init(claudeDataPath: String? = nil, metadataStore: SessionMetadataStore? = nil) {
    self.claudeDataPath = claudeDataPath ?? (NSHomeDirectory() + "/.claude")
    self.metadataStore = metadataStore
  }

  // MARK: - Repository Management

  /// Adds a repository to monitor and detects its worktrees
  /// - Parameter path: Path to the git repository
  /// - Returns: The created SelectedRepository with detected worktrees
  @discardableResult
  public func addRepository(_ path: String) async -> SelectedRepository? {
    // Check if already added
    guard !selectedRepositories.contains(where: { $0.path == path }) else {
      return selectedRepositories.first { $0.path == path }
    }

    // Detect worktrees for this repository
    let worktrees = await detectWorktrees(at: path)

    let repository = SelectedRepository(
      path: path,
      worktrees: worktrees,
      isExpanded: true
    )

    selectedRepositories.append(repository)
    invalidateHistoryCache()

    // Scan for sessions in the new repository
    // Skip worktree re-detection since we just detected worktrees for this repo
    await refreshSessions(skipWorktreeRedetection: true)

    return repository
  }

  /// Adds multiple repositories at once, detecting worktrees in parallel and
  /// calling refreshSessions only once at the end (instead of N times).
  public func addRepositories(_ paths: [String]) async {
    // Filter out already-added repos
    let newPaths = paths.filter { path in
      !selectedRepositories.contains(where: { $0.path == path })
    }
    guard !newPaths.isEmpty else { return }

    // Detect worktrees for all new repos in parallel
    let allWorktrees = await detectWorktreesBatch(repoPaths: newPaths)

    for path in newPaths {
      let worktrees = allWorktrees[path] ?? []
      let repository = SelectedRepository(
        path: path,
        worktrees: worktrees,
        isExpanded: true
      )
      selectedRepositories.append(repository)
    }

    invalidateHistoryCache()

    // Single refreshSessions call for all repos
    await refreshSessions(skipWorktreeRedetection: true)
  }

  /// Restores selected repositories and worktrees without scanning every session.
  /// Used on app launch so the main monitored-session list can appear quickly.
  public func restoreRepositoriesSkeleton(_ paths: [String]) async -> [SelectedRepository] {
    var seen: Set<String> = []
    let uniquePaths = paths.filter { seen.insert($0).inserted }

    guard !uniquePaths.isEmpty else {
      selectedRepositories = []
      invalidateHistoryCache()
      repositoriesSubject.send([])
      return []
    }

    let allWorktrees = await detectWorktreesBatch(repoPaths: uniquePaths)
    selectedRepositories = uniquePaths.map { path in
      SelectedRepository(
        path: path,
        worktrees: allWorktrees[path] ?? [],
        isExpanded: true
      )
    }
    invalidateHistoryCache()
    repositoriesSubject.send(selectedRepositories)
    return selectedRepositories
  }

  /// Removes a repository from monitoring
  /// - Parameter path: Path to the repository to remove
  public func removeRepository(_ path: String) async {
    selectedRepositories.removeAll { $0.path == path }
    invalidateHistoryCache()
    repositoriesSubject.send(selectedRepositories)
  }

  /// Returns currently selected repositories
  public func getSelectedRepositories() async -> [SelectedRepository] {
    selectedRepositories
  }

  /// Sets the list of selected repositories (for persistence restoration)
  public func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    selectedRepositories = repositories
    invalidateHistoryCache()
    await refreshSessions()
  }

  /// Loads only the requested Claude sessions from their JSONL files.
  /// This avoids parsing the global history file during app launch.
  public func loadSessions(ids: Set<String>) async -> [CLISession] {
    guard !ids.isEmpty else { return [] }
    let claudeDataPath = claudeDataPath
    let filesBySessionId = await Task.detached(priority: .userInitiated) {
      CLISessionMonitorService.findClaudeSessionFiles(
        sessionIds: ids,
        claudeDataPath: claudeDataPath
      )
    }.value

    var sessions: [CLISession] = []
    for sessionId in ids {
      guard let filePath = filesBySessionId[sessionId],
            let session = restoreSession(sessionId: sessionId, filePath: filePath) else {
        continue
      }
      sessions.append(session)
    }

    return sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
  }

  // MARK: - Session Scanning

  /// Refreshes sessions for all selected repositories
  /// - Parameter skipWorktreeRedetection: When true, skips worktree re-detection (used after adding a new repo)
  public func refreshSessions(skipWorktreeRedetection: Bool = false) async {
    guard !selectedRepositories.isEmpty else {
      repositoriesSubject.send([])
      return
    }

    // Re-detect worktrees for all repositories to pick up newly created ones
    if !skipWorktreeRedetection {
      let repoCount = selectedRepositories.count
      AppLogger.git.info("[MonitorService] refreshSessions worktree re-detection start repos=\(repoCount)")
      // Detect worktrees for all repos in parallel (invalidate cache for full refresh)
      worktreeCache.removeAll()
      let allWorktrees = await detectWorktreesBatch(
        repoPaths: selectedRepositories.map { $0.path }
      )
      AppLogger.git.info("[MonitorService] refreshSessions worktree re-detection end repos=\(repoCount)")

      // Merge detected worktrees with existing state
      for index in selectedRepositories.indices {
        let repoPath = selectedRepositories[index].path
        let detectedWorktrees = allWorktrees[repoPath] ?? []

        // Merge: keep existing worktrees (preserves isExpanded), add new ones, remove deleted
        var mergedWorktrees: [WorktreeBranch] = []
        for detected in detectedWorktrees {
          if var existing = selectedRepositories[index].worktrees.first(where: { $0.path == detected.path }) {
            // Keep existing worktree (preserves isExpanded state), but update branch name
            existing.name = detected.name  // Update branch name from git
            existing.sessions = []  // Will be repopulated below
            mergedWorktrees.append(existing)
          } else {
            // Add new worktree
            mergedWorktrees.append(detected)
          }
        }
        selectedRepositories[index].worktrees = mergedWorktrees
      }
    }

    // Get all paths to filter by (including worktree paths)
    let allPaths = getAllMonitoredPaths()

    // Parse history for selected paths only
    let sessionSummaries = await parseHistoryForPaths(allPaths)

    // Build a map of session ID -> (gitBranch, slug) (read from session files in parallel)
    let sessionMetadata = await readSessionMetadataBatch(sessionSummaries: sessionSummaries)

    // Build sessions and assign to worktrees
    var updatedRepositories = selectedRepositories

    // Track which sessions have been assigned to prevent duplicates
    var assignedSessionIds: Set<String> = []

    // Fetch all existing repo mappings for sessions we're processing
    let allSessionIds = Array(sessionSummaries.keys)
    pruneSessionMetadataCache(retaining: Set(allSessionIds))
    let existingMappings = try? await metadataStore?.getRepoMappings(for: allSessionIds)

    for repoIndex in updatedRepositories.indices {
      // Track the current repository path for this iteration
      let currentRepoPath = updatedRepositories[repoIndex].path

      for worktreeIndex in updatedRepositories[repoIndex].worktrees.indices {
        let worktreePath = updatedRepositories[repoIndex].worktrees[worktreeIndex].path
        let worktreeBranch = updatedRepositories[repoIndex].worktrees[worktreeIndex].name
        let isWorktreeEntry = updatedRepositories[repoIndex].worktrees[worktreeIndex].isWorktree

        // Find sessions for this worktree
        var sessions: [CLISession] = []

        for (sessionId, summary) in sessionSummaries {
          // Skip if already assigned to another worktree
          guard !assignedSessionIds.contains(sessionId) else { continue }

          // PRIMARY: Exact path match - session's project directory matches this worktree
          // This is the most reliable criterion because summary.project IS where the session runs
          let pathMatchesWorktree = summary.project == worktreePath

          if pathMatchesWorktree {
            // This is definitively the correct worktree - use this session
            let metadata = sessionMetadata[sessionId]

            // Check repo mapping first - prevents collision when different repos reuse the same path
            if let mapping = existingMappings?[sessionId] {
              // Session has existing mapping - verify parent repo matches
              guard mapping.parentRepoPath == currentRepoPath else {
                // Session belongs to different repo, skip
                continue
              }
            }

            // Verify branch matches to prevent session collision across repositories
            // When a worktree path is reused by a different repository, branch names will differ
            let branchMatches: Bool
            if let sessionBranch = metadata?.branch {
              branchMatches = sessionBranch == worktreeBranch
            } else {
              // No branch info - only assign to non-worktree entries (main repo)
              branchMatches = !isWorktreeEntry
            }

            // Skip if branch doesn't match - session belongs to a different repo
            guard branchMatches else { continue }

            // If no mapping exists, create one for this session
            if existingMappings?[sessionId] == nil {
              let mapping = SessionRepoMapping(
                sessionId: sessionId,
                parentRepoPath: currentRepoPath,
                worktreePath: worktreePath
              )
              try? await metadataStore?.setRepoMapping(mapping)
            }

            // Check if session is active
            let encodedPath = summary.project.claudeProjectPathEncoded
            let sessionFilePath = "\(claudeDataPath)/projects/\(encodedPath)/\(sessionId).jsonl"
            var isActive = false
            if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFilePath),
               let modDate = attrs[FileAttributeKey.modificationDate] as? Date {
              let secondsAgo = Date().timeIntervalSince(modDate)
              isActive = secondsAgo < 60
            }

            let session = CLISession(
              id: sessionId,
              projectPath: summary.project,
              branchName: metadata?.branch ?? worktreeBranch,
              isWorktree: isWorktreeEntry,
              lastActivityAt: summary.lastActivityDate,
              messageCount: summary.messageCount,
              isActive: isActive,
              firstMessage: summary.firstDisplay,
              lastMessage: summary.lastDisplay,
              slug: metadata?.slug
            )

            sessions.append(session)
            assignedSessionIds.insert(sessionId)
            continue
          }

          // FALLBACK: For sessions in subdirectories of THIS worktree
          // (e.g., session in /repo/subfolder should match worktree at /repo)
          // This must check the CURRENT worktree path, not all repo paths,
          // otherwise sessions from other worktrees would be incorrectly assigned
          let pathIsSubdirectory = summary.project.hasPrefix(worktreePath + "/")
          guard pathIsSubdirectory else { continue }

          // Get session's metadata from session file
          let metadata = sessionMetadata[sessionId]

          // Check repo mapping first - prevents collision when different repos reuse the same path
          if let mapping = existingMappings?[sessionId] {
            // Session has existing mapping - verify parent repo matches
            guard mapping.parentRepoPath == currentRepoPath else {
              // Session belongs to different repo, skip
              continue
            }
          }

          // Match by branch name as fallback
          let branchMatches: Bool
          if let sessionBranch = metadata?.branch {
            // Session has branch info - match by branch
            branchMatches = sessionBranch == worktreeBranch
          } else {
            // No branch info - only assign to main worktree (non-worktree entry)
            // This handles old sessions that don't have gitBranch in their file
            branchMatches = !isWorktreeEntry
          }

          guard branchMatches else { continue }

          // If no mapping exists, create one for this session
          if existingMappings?[sessionId] == nil {
            let mapping = SessionRepoMapping(
              sessionId: sessionId,
              parentRepoPath: currentRepoPath,
              worktreePath: worktreePath
            )
            try? await metadataStore?.setRepoMapping(mapping)
          }

          // Check if session is active by looking at session file modification time
          // A session is active if its .jsonl file was modified in the last 60 seconds
          let encodedPath = summary.project.claudeProjectPathEncoded
          let sessionFilePath = "\(claudeDataPath)/projects/\(encodedPath)/\(sessionId).jsonl"
          var isActive = false
          if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFilePath),
             let modDate = attrs[FileAttributeKey.modificationDate] as? Date {
            let secondsAgo = Date().timeIntervalSince(modDate)
            isActive = secondsAgo < 60
          }

          let session = CLISession(
            id: sessionId,
            projectPath: summary.project,
            branchName: metadata?.branch ?? worktreeBranch,
            isWorktree: isWorktreeEntry,
            lastActivityAt: summary.lastActivityDate,
            messageCount: summary.messageCount,
            isActive: isActive,
            firstMessage: summary.firstDisplay,
            lastMessage: summary.lastDisplay,
            slug: metadata?.slug
          )

          sessions.append(session)
          assignedSessionIds.insert(sessionId)
        }

        // Sort by last activity
        sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        updatedRepositories[repoIndex].worktrees[worktreeIndex].sessions = sessions
      }
    }

    selectedRepositories = updatedRepositories
    repositoriesSubject.send(selectedRepositories)
  }

  // MARK: - Message Utilities

  // TEMPORARY FIX: Skip greetings to show meaningful session previews.
  // This works around the issue where sessions disappear from the Hub during refresh
  // when no session ID is found (happens after only the first message is sent).
  // TODO: Remove once the session refresh/ID detection issue is properly fixed.


  // MARK: - Worktree Detection

  private func detectWorktrees(at repoPath: String) async -> [WorktreeBranch] {
    // Use GitWorktreeDetector to list all worktrees
    let worktrees = await GitWorktreeDetector.listWorktrees(at: repoPath)

    if worktrees.isEmpty {
      // If no worktrees detected, just use the main repo with current branch
      let info = await GitWorktreeDetector.detectWorktreeInfo(for: repoPath)

      return [
        WorktreeBranch(
          name: info?.branch ?? "main",
          path: repoPath,
          isWorktree: false,
          sessions: []
        )
      ]
    }

    return worktrees.map { info in
      WorktreeBranch(
        name: info.branch ?? URL(fileURLWithPath: info.path).lastPathComponent,
        path: info.path,
        isWorktree: info.isWorktree,
        sessions: []
      )
    }
  }

  /// Detects worktrees for multiple repositories in parallel.
  /// When `useCache` is true, returns cached results for repos that have been detected before.
  /// - Parameters:
  ///   - repoPaths: Array of repository paths to detect worktrees for
  ///   - useCache: When true, skips detection for repos with cached results
  /// - Returns: Dictionary mapping repository paths to their detected worktrees
  private func detectWorktreesBatch(repoPaths: [String], useCache: Bool = false) async -> [String: [WorktreeBranch]] {
    let start = ContinuousClock.now

    // Separate cached and uncached repos
    var results: [String: [WorktreeBranch]] = [:]
    var pathsToDetect: [String] = []

    if useCache {
      for path in repoPaths {
        if let cached = worktreeCache[path] {
          results[path] = cached
        } else {
          pathsToDetect.append(path)
        }
      }
    } else {
      pathsToDetect = repoPaths
    }

    // Detect worktrees for uncached repos in parallel
    if !pathsToDetect.isEmpty {
      let detected = await withTaskGroup(of: (String, [WorktreeBranch]).self) { group in
        for repoPath in pathsToDetect {
          group.addTask {
            let worktrees = await self.detectWorktrees(at: repoPath)
            return (repoPath, worktrees)
          }
        }

        var detected: [String: [WorktreeBranch]] = [:]
        for await (path, worktrees) in group {
          detected[path] = worktrees
        }
        return detected
      }

      // Update cache and results
      for (path, worktrees) in detected {
        worktreeCache[path] = worktrees
        results[path] = worktrees
      }
    }

    let elapsed = ContinuousClock.now - start
    let totalWorktrees = results.values.reduce(0) { $0 + $1.count }
    let cachedCount = repoPaths.count - pathsToDetect.count
    AppLogger.git.info("[MonitorService] detectWorktreesBatch repos=\(repoPaths.count) cached=\(cachedCount) detected=\(pathsToDetect.count) totalWorktrees=\(totalWorktrees) elapsed=\(elapsed, privacy: .public)")
    return results
  }

  // MARK: - Path Collection

  private func getAllMonitoredPaths() -> Set<String> {
    var paths = Set<String>()
    for repo in selectedRepositories {
      paths.insert(repo.path)
      for worktree in repo.worktrees {
        paths.insert(worktree.path)
      }
    }
    return paths
  }

  private func restoreSession(sessionId: String, filePath: String) -> CLISession? {
    guard let data = FileManager.default.contents(atPath: filePath),
          let content = String(data: data, encoding: .utf8) else {
      return nil
    }

    var projectPath: String?
    var branchName: String?
    var slug: String?
    var firstMessage: String?
    var lastMessage: String?
    var messageCount = 0
    var lastActivityAt: Date?

    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let lineData = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
        continue
      }

      if let lineSessionId = json["sessionId"] as? String, lineSessionId != sessionId {
        return nil
      }
      if projectPath == nil, let cwd = json["cwd"] as? String {
        projectPath = cwd
      }
      if branchName == nil, let gitBranch = json["gitBranch"] as? String {
        branchName = gitBranch
      }
      if slug == nil, let sessionSlug = json["slug"] as? String {
        slug = sessionSlug
      }
      if let timestamp = Self.parseISO8601Date(json["timestamp"] as? String),
         lastActivityAt.map({ timestamp > $0 }) ?? true {
        lastActivityAt = timestamp
      }

      guard let type = json["type"] as? String else { continue }
      if type == "user" || type == "assistant" {
        messageCount += 1
      }
      if type == "user",
         let preview = Self.extractClaudeTextPreview(from: json),
         !preview.isEmpty {
        if firstMessage == nil {
          firstMessage = preview
        }
        lastMessage = preview
      }
    }

    guard let projectPath else { return nil }
    let worktree = worktreeInfo(containing: projectPath)
    let fileModifiedAt = fileModificationDate(filePath)
    let activityAt = [lastActivityAt, fileModifiedAt].compactMap { $0 }.max() ?? Date()

    return CLISession(
      id: sessionId,
      projectPath: projectPath,
      branchName: branchName ?? worktree.branchName,
      isWorktree: worktree.isWorktree,
      lastActivityAt: activityAt,
      messageCount: messageCount,
      isActive: fileModifiedAt.map { Date().timeIntervalSince($0) < 60 } ?? false,
      firstMessage: firstMessage,
      lastMessage: lastMessage,
      slug: slug,
      sessionFilePath: filePath
    )
  }

  private func worktreeInfo(containing projectPath: String) -> (branchName: String?, isWorktree: Bool) {
    let matchingWorktree = selectedRepositories
      .flatMap(\.worktrees)
      .filter { projectPath == $0.path || projectPath.hasPrefix($0.path + "/") }
      .max { $0.path.count < $1.path.count }

    return (matchingWorktree?.name, matchingWorktree?.isWorktree ?? false)
  }

  private func fileModificationDate(_ path: String) -> Date? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let modDate = attrs[.modificationDate] as? Date else {
      return nil
    }
    return modDate
  }

  private static func findClaudeSessionFiles(
    sessionIds: Set<String>,
    claudeDataPath: String
  ) -> [String: String] {
    let projectsRoot = URL(fileURLWithPath: claudeDataPath).appendingPathComponent("projects")
    guard let enumerator = FileManager.default.enumerator(
      at: projectsRoot,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return [:]
    }

    var results: [String: String] = [:]
    let expectedFileNames = Dictionary(uniqueKeysWithValues: sessionIds.map { ("\($0).jsonl", $0) })

    for case let url as URL in enumerator {
      guard url.pathExtension == "jsonl",
            !url.path.contains("/subagents/"),
            let sessionId = expectedFileNames[url.lastPathComponent],
            results[sessionId] == nil else {
        continue
      }
      results[sessionId] = url.path
    }

    return results
  }

  private static func extractClaudeTextPreview(from json: [String: Any]) -> String? {
    guard let message = json["message"] as? [String: Any] else { return nil }

    if let text = message["content"] as? String {
      return cleanPreview(text)
    }

    guard let blocks = message["content"] as? [[String: Any]] else { return nil }
    let text = blocks.compactMap { block -> String? in
      guard block["type"] as? String == "text" else { return nil }
      return block["text"] as? String
    }.joined(separator: " ")

    return cleanPreview(text)
  }

  private static func cleanPreview(_ text: String) -> String? {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.prefix(500))
  }

  private static func parseISO8601Date(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }

  // MARK: - Session File Parsing

  /// Metadata extracted from a session file
  private struct SessionMetadata: Sendable {
    let branch: String?
    let slug: String?
  }

  struct HistorySessionSummary: Sendable, Equatable {
    var project: String
    var firstDisplay: String
    var lastDisplay: String
    var firstTimestamp: Int64
    var lastTimestamp: Int64
    var messageCount: Int

    var lastActivityDate: Date {
      Date(timeIntervalSince1970: TimeInterval(lastTimestamp) / 1000.0)
    }
  }

  /// Reads gitBranch and slug from multiple session files in parallel using Task.detached.
  /// Uses `sessionMetadataCache` to skip re-reading files for known sessions.
  /// - Parameter sessionSummaries: Dictionary of session IDs to their history summaries
  /// - Returns: Dictionary mapping session IDs to their metadata (branch and slug)
  private func readSessionMetadataBatch(sessionSummaries: [String: HistorySessionSummary]) async -> [String: SessionMetadata] {
    let claudePath = claudeDataPath  // Capture for sendable closure

    // Separate cached from uncached sessions
    var results: [String: SessionMetadata] = [:]
    var uncachedEntries: [(sessionId: String, filePath: String)] = []

    for (sessionId, summary) in sessionSummaries {
      if let cached = sessionMetadataCache[sessionId] {
        results[sessionId] = cached
      } else {
        let encodedPath = summary.project.claudeProjectPathEncoded
        let filePath = "\(claudePath)/projects/\(encodedPath)/\(sessionId).jsonl"
        uncachedEntries.append((sessionId, filePath))
      }
    }

    guard !uncachedEntries.isEmpty else { return results }

    let filesToRead = uncachedEntries  // Capture for sendable closure

    let newMetadata = await Task.detached(priority: .userInitiated) {
      // Read all files in parallel using withTaskGroup
      return await withTaskGroup(of: (String, SessionMetadata?).self) { group in
        for (sessionId, filePath) in filesToRead {
          group.addTask {
            // Read first 16KB to find gitBranch and slug (slug may appear after first few lines)
            guard let handle = FileHandle(forReadingAtPath: filePath) else {
              return (sessionId, nil)
            }
            defer { try? handle.close() }

            // Read first 16KB - slug may appear several lines into the file
            guard let data = try? handle.read(upToCount: 16384),
                  let content = String(data: data, encoding: .utf8) else {
              return (sessionId, nil)
            }

            // Parse lines looking for gitBranch and slug
            var foundBranch: String?
            var foundSlug: String?

            for line in content.components(separatedBy: .newlines) {
              guard !line.isEmpty,
                    let jsonData = line.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
              }

              if foundBranch == nil, let gitBranch = json["gitBranch"] as? String {
                foundBranch = gitBranch
              }
              if foundSlug == nil, let slug = json["slug"] as? String {
                foundSlug = slug
              }

              // Early exit if we found both
              if foundBranch != nil && foundSlug != nil {
                break
              }
            }

            if foundBranch != nil || foundSlug != nil {
              return (sessionId, SessionMetadata(branch: foundBranch, slug: foundSlug))
            }
            return (sessionId, nil)
          }
        }

        var newResults: [String: SessionMetadata] = [:]
        for await (sessionId, metadata) in group {
          if let metadata = metadata {
            newResults[sessionId] = metadata
          }
        }
        return newResults
      }
    }.value

    // Update cache and merge into results
    for (sessionId, metadata) in newMetadata {
      sessionMetadataCache[sessionId] = metadata
      results[sessionId] = metadata
    }

    return results
  }

  // MARK: - Filtered History Parsing

  /// Parses history.jsonl incrementally — only reads new bytes since last parse.
  /// On first call or if the file was truncated, does a full parse.
  /// Uses Task.detached to run heavy I/O and parsing off the actor's isolation context.
  private func parseHistoryForPaths(_ paths: Set<String>) async -> [String: HistorySessionSummary] {
    let historyPath = claudeDataPath + "/history.jsonl"
    let previousOffset = lastHistoryOffset
    let previousSummaries = cachedHistorySummaries

    let (newSummaries, newOffset) = await Task.detached(priority: .userInitiated) {
      // Check file size
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: historyPath),
            let fileSize = attrs[.size] as? UInt64 else {
        return ([String: HistorySessionSummary](), UInt64(0))
      }

      // If file was truncated or this is the first parse, do full parse
      let needsFullParse = fileSize < previousOffset || previousOffset == 0

      let data: Data

      if needsFullParse {
        guard let fullData = FileManager.default.contents(atPath: historyPath) else {
          return ([String: HistorySessionSummary](), UInt64(0))
        }
        data = fullData
      } else if fileSize > previousOffset {
        // Incremental: read only new bytes
        guard let handle = FileHandle(forReadingAtPath: historyPath) else {
          return (previousSummaries, previousOffset)
        }
        defer { try? handle.close() }
        do {
          try handle.seek(toOffset: previousOffset)
          guard let newData = try handle.read(upToCount: Int(fileSize - previousOffset)) else {
            return (previousSummaries, previousOffset)
          }
          data = newData
        } catch {
          return (previousSummaries, previousOffset)
        }
      } else {
        // No new data
        return (previousSummaries, previousOffset)
      }

      guard let content = String(data: data, encoding: .utf8) else {
        return (needsFullParse ? [String: HistorySessionSummary]() : previousSummaries, needsFullParse ? UInt64(0) : previousOffset)
      }

      let decoder = JSONDecoder()
      let parsed = content
        .components(separatedBy: .newlines)
        .compactMap { line -> HistoryEntry? in
          guard !line.isEmpty,
                let jsonData = line.data(using: .utf8),
                let entry = try? decoder.decode(HistoryEntry.self, from: jsonData) else {
            return nil
          }
          return entry
        }
      var summaries = needsFullParse ? [String: HistorySessionSummary]() : previousSummaries
      CLISessionMonitorService.accumulateHistoryEntries(parsed, filteredBy: paths, into: &summaries)
      return (summaries, fileSize)
    }.value

    // Update cached state
    cachedHistorySummaries = newSummaries
    lastHistoryOffset = newOffset

    return newSummaries
  }

  static func accumulateHistoryEntries(
    _ entries: [HistoryEntry],
    filteredBy paths: Set<String>,
    into summaries: inout [String: HistorySessionSummary]
  ) {
    for entry in entries where matchesMonitoredPath(entry.project, monitoredPaths: paths) {
      mergeHistoryEntry(entry, into: &summaries)
    }
  }

  static func matchesMonitoredPath(_ project: String, monitoredPaths: Set<String>) -> Bool {
    monitoredPaths.contains { path in
      project == path || project.hasPrefix(path + "/")
    }
  }

  static func mergeHistoryEntry(_ entry: HistoryEntry, into summaries: inout [String: HistorySessionSummary]) {
    if var existing = summaries[entry.sessionId] {
      if entry.timestamp < existing.firstTimestamp {
        existing.firstTimestamp = entry.timestamp
        existing.firstDisplay = entry.display
      }

      if entry.timestamp >= existing.lastTimestamp {
        existing.lastTimestamp = entry.timestamp
        existing.lastDisplay = entry.display
        existing.project = entry.project
      }

      existing.messageCount += 1
      summaries[entry.sessionId] = existing
    } else {
      summaries[entry.sessionId] = HistorySessionSummary(
        project: entry.project,
        firstDisplay: entry.display,
        lastDisplay: entry.display,
        firstTimestamp: entry.timestamp,
        lastTimestamp: entry.timestamp,
        messageCount: 1
      )
    }
  }

  private func invalidateHistoryCache() {
    cachedHistorySummaries = [:]
    lastHistoryOffset = 0
  }

  private func pruneSessionMetadataCache(retaining sessionIds: Set<String>) {
    sessionMetadataCache = sessionMetadataCache.filter { sessionIds.contains($0.key) }
  }

}

// MARK: - Protocol Conformance

extension CLISessionMonitorService: SessionMonitorServiceProtocol {}
