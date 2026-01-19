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

  // MARK: - Publishers

  // Using nonisolated(unsafe) since CurrentValueSubject is internally thread-safe
  private nonisolated(unsafe) let repositoriesSubject = CurrentValueSubject<[SelectedRepository], Never>([])
  public nonisolated var repositoriesPublisher: AnyPublisher<[SelectedRepository], Never> {
    repositoriesSubject.eraseToAnyPublisher()
  }

  // MARK: - State

  private var selectedRepositories: [SelectedRepository] = []

  // MARK: - Initialization

  public init(claudeDataPath: String? = nil) {
    self.claudeDataPath = claudeDataPath ?? (NSHomeDirectory() + "/.claude")
  }

  // MARK: - Repository Management

  /// Adds a repository to monitor and detects its worktrees
  /// - Parameter path: Path to the git repository
  /// - Returns: The created SelectedRepository with detected worktrees
  @discardableResult
  public func addRepository(_ path: String) async -> SelectedRepository? {
    let startTotal = CFAbsoluteTimeGetCurrent()
    print("[CLIMonitorService] addRepository called for: \(path)")

    // Check if already added
    guard !selectedRepositories.contains(where: { $0.path == path }) else {
      print("[CLIMonitorService] Repository already added, returning existing")
      return selectedRepositories.first { $0.path == path }
    }

    // Detect worktrees for this repository
    print("[CLIMonitorService] Detecting worktrees...")
    let startWorktrees = CFAbsoluteTimeGetCurrent()
    let worktrees = await detectWorktrees(at: path)
    print("[CLIMonitorService] ⏱️ detectWorktrees: \(CFAbsoluteTimeGetCurrent() - startWorktrees)s")
    print("[CLIMonitorService] Detected \(worktrees.count) worktrees")

    let repository = SelectedRepository(
      path: path,
      worktrees: worktrees,
      isExpanded: true
    )

    selectedRepositories.append(repository)
    print("[CLIMonitorService] Repository added, now refreshing sessions...")

    // Scan for sessions in the new repository
    // Skip worktree re-detection since we just detected worktrees for this repo
    await refreshSessions(skipWorktreeRedetection: true)
    print("[CLIMonitorService] ⏱️ addRepository total: \(CFAbsoluteTimeGetCurrent() - startTotal)s")

    return repository
  }

  /// Removes a repository from monitoring
  /// - Parameter path: Path to the repository to remove
  public func removeRepository(_ path: String) async {
    selectedRepositories.removeAll { $0.path == path }
    repositoriesSubject.send(selectedRepositories)
  }

  /// Returns currently selected repositories
  public func getSelectedRepositories() -> [SelectedRepository] {
    selectedRepositories
  }

  /// Sets the list of selected repositories (for persistence restoration)
  public func setSelectedRepositories(_ repositories: [SelectedRepository]) async {
    selectedRepositories = repositories
    await refreshSessions()
  }

  // MARK: - Session Scanning

  /// Refreshes sessions for all selected repositories
  /// - Parameter skipWorktreeRedetection: When true, skips worktree re-detection (used after adding a new repo)
  public func refreshSessions(skipWorktreeRedetection: Bool = false) async {
    let startRefresh = CFAbsoluteTimeGetCurrent()
    print("[CLIMonitorService] refreshSessions called")

    guard !selectedRepositories.isEmpty else {
      print("[CLIMonitorService] No repositories, sending empty")
      repositoriesSubject.send([])
      return
    }

    // Re-detect worktrees for all repositories to pick up newly created ones
    if !skipWorktreeRedetection {
      let startWorktreeRedetect = CFAbsoluteTimeGetCurrent()
      print("[CLIMonitorService] Re-detecting worktrees in parallel...")

      // Detect worktrees for all repos in parallel
      let allWorktrees = await detectWorktreesBatch(
        repoPaths: selectedRepositories.map { $0.path }
      )

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
            print("[CLIMonitorService] Found new worktree: \(detected.path)")
            mergedWorktrees.append(detected)
          }
        }
        selectedRepositories[index].worktrees = mergedWorktrees
      }
      print("[CLIMonitorService] ⏱️ worktree re-detection: \(CFAbsoluteTimeGetCurrent() - startWorktreeRedetect)s")
    } else {
      print("[CLIMonitorService] Skipping worktree re-detection (just added repo)")
    }

    // Get all paths to filter by (including worktree paths)
    let allPaths = getAllMonitoredPaths()
    print("[CLIMonitorService] Monitoring \(allPaths.count) paths")

    // Parse history for selected paths only
    let startHistory = CFAbsoluteTimeGetCurrent()
    print("[CLIMonitorService] Parsing history...")
    let historyEntries = await parseHistoryForPaths(allPaths)
    print("[CLIMonitorService] ⏱️ parseHistory: \(CFAbsoluteTimeGetCurrent() - startHistory)s")
    print("[CLIMonitorService] Found \(historyEntries.count) history entries")

    // Group entries by session ID
    let sessionEntries = Dictionary(grouping: historyEntries) { $0.sessionId }
    print("[CLIMonitorService] Grouped into \(sessionEntries.count) sessions")

    // Build a map of session ID -> gitBranch (read from session files in parallel)
    let startBranches = CFAbsoluteTimeGetCurrent()
    let sessionBranches = await readBranchInfoBatch(sessionEntries: sessionEntries)
    print("[CLIMonitorService] ⏱️ readBranchInfo: \(CFAbsoluteTimeGetCurrent() - startBranches)s")
    print("[CLIMonitorService] Read branch info for \(sessionBranches.count) sessions")

    // Debug: Print unique branches found
    let uniqueBranches = Set(sessionBranches.values)
    print("[CLIMonitorService] Unique session branches: \(uniqueBranches)")

    // Debug: Check which sessions have worktree branches
    for (sessionId, branch) in sessionBranches {
      if branch.contains("refactor-math") {
        if let entries = sessionEntries[sessionId], let first = entries.first {
          print("[CLIMonitorService] DEBUG: Session \(sessionId.prefix(8)) branch='\(branch)' project='\(first.project)'")
        }
      }
    }

    // Build sessions and assign to worktrees
    var updatedRepositories = selectedRepositories

    // Collect all worktree branch names for this repository set
    var worktreeBranchNames: Set<String> = []
    for repo in updatedRepositories {
      for worktree in repo.worktrees {
        worktreeBranchNames.insert(worktree.name)
      }
    }
    print("[CLIMonitorService] Worktree branch names: \(worktreeBranchNames)")

    for repoIndex in updatedRepositories.indices {
      let repoPath = updatedRepositories[repoIndex].path

      // Collect all paths for this repository (main + all worktrees)
      let allRepoPaths = [repoPath] + updatedRepositories[repoIndex].worktrees.map { $0.path }

      for worktreeIndex in updatedRepositories[repoIndex].worktrees.indices {
        let worktreePath = updatedRepositories[repoIndex].worktrees[worktreeIndex].path
        let worktreeBranch = updatedRepositories[repoIndex].worktrees[worktreeIndex].name
        let isWorktreeEntry = updatedRepositories[repoIndex].worktrees[worktreeIndex].isWorktree

        // Find sessions for this worktree
        var sessions: [CLISession] = []

        for (sessionId, entries) in sessionEntries {
          guard let firstEntry = entries.first else { continue }

          // Check if this session belongs to this repository:
          // Session's project path must match the repo OR any of its worktree paths
          let pathMatchesRepo = allRepoPaths.contains { path in
            firstEntry.project.hasPrefix(path) || firstEntry.project == path
          }
          guard pathMatchesRepo else { continue }

          // Get session's branch from session file
          let sessionBranch = sessionBranches[sessionId]

          // Match by branch name
          let branchMatches: Bool
          if let sessionBranch = sessionBranch {
            // Session has branch info - match by branch
            branchMatches = sessionBranch == worktreeBranch
            // Debug: log when we find a session with a worktree branch
            if worktreeBranchNames.contains(sessionBranch) && sessionBranch != "main" {
              print("[CLIMonitorService] DEBUG: Session \(sessionId.prefix(8)) has branch '\(sessionBranch)', comparing to worktree '\(worktreeBranch)', matches: \(branchMatches)")
            }
          } else {
            // No branch info - only assign to main worktree (non-worktree entry)
            // This handles old sessions that don't have gitBranch in their file
            branchMatches = !isWorktreeEntry
          }

          guard branchMatches else { continue }

          // Check if session is active by looking at session file modification time
          // A session is active if its .jsonl file was modified in the last 60 seconds
          let encodedPath = firstEntry.project.replacingOccurrences(of: "/", with: "-")
          let sessionFilePath = "\(claudeDataPath)/projects/\(encodedPath)/\(sessionId).jsonl"
          var isActive = false
          if let attrs = try? FileManager.default.attributesOfItem(atPath: sessionFilePath),
             let modDate = attrs[FileAttributeKey.modificationDate] as? Date {
            let secondsAgo = Date().timeIntervalSince(modDate)
            isActive = secondsAgo < 60
            if isActive {
              print("[CLIMonitorService] Session \(sessionId.prefix(8)) is ACTIVE (modified \(Int(secondsAgo))s ago)")
            }
          }

          // Get the first and last message (sorted by timestamp)
          let sortedEntries = entries.sorted { $0.timestamp < $1.timestamp }
          let firstMessage = sortedEntries.first?.display
          let lastMessage = sortedEntries.last?.display

          let session = CLISession(
            id: sessionId,
            projectPath: firstEntry.project,
            branchName: sessionBranch ?? worktreeBranch,
            isWorktree: isWorktreeEntry,
            lastActivityAt: entries.map { $0.date }.max() ?? Date(),
            messageCount: entries.count,
            isActive: isActive,
            firstMessage: firstMessage,
            lastMessage: lastMessage
          )

          sessions.append(session)
        }

        // Sort by last activity
        sessions.sort { $0.lastActivityAt > $1.lastActivityAt }
        updatedRepositories[repoIndex].worktrees[worktreeIndex].sessions = sessions
        print("[CLIMonitorService] Worktree '\(worktreeBranch)' matched \(sessions.count) sessions")
      }
    }

    selectedRepositories = updatedRepositories
    print("[CLIMonitorService] Sending \(selectedRepositories.count) repositories to subject")
    repositoriesSubject.send(selectedRepositories)
    print("[CLIMonitorService] ⏱️ refreshSessions total: \(CFAbsoluteTimeGetCurrent() - startRefresh)s")
  }

  // MARK: - Worktree Detection

  private func detectWorktrees(at repoPath: String) async -> [WorktreeBranch] {
    print("[CLIMonitorService] detectWorktrees called for: \(repoPath)")

    // Use GitWorktreeDetector to list all worktrees
    print("[CLIMonitorService] Calling GitWorktreeDetector.listWorktrees...")
    let worktrees = await GitWorktreeDetector.listWorktrees(at: repoPath)
    print("[CLIMonitorService] listWorktrees returned \(worktrees.count) results")

    if worktrees.isEmpty {
      // If no worktrees detected, just use the main repo with current branch
      print("[CLIMonitorService] No worktrees, calling detectWorktreeInfo...")
      let info = await GitWorktreeDetector.detectWorktreeInfo(for: repoPath)
      print("[CLIMonitorService] detectWorktreeInfo returned: \(String(describing: info))")

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

  /// Detects worktrees for multiple repositories in parallel
  /// - Parameter repoPaths: Array of repository paths to detect worktrees for
  /// - Returns: Dictionary mapping repository paths to their detected worktrees
  private func detectWorktreesBatch(repoPaths: [String]) async -> [String: [WorktreeBranch]] {
    await withTaskGroup(of: (String, [WorktreeBranch]).self) { group in
      for repoPath in repoPaths {
        group.addTask {
          let worktrees = await self.detectWorktrees(at: repoPath)
          return (repoPath, worktrees)
        }
      }

      var results: [String: [WorktreeBranch]] = [:]
      for await (path, worktrees) in group {
        results[path] = worktrees
      }
      return results
    }
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

  // MARK: - Session File Parsing

  /// Reads gitBranch from multiple session files in parallel using Task.detached
  /// - Parameter sessionEntries: Dictionary of session IDs to their history entries
  /// - Returns: Dictionary mapping session IDs to their git branch names
  private func readBranchInfoBatch(sessionEntries: [String: [HistoryEntry]]) async -> [String: String] {
    let claudePath = claudeDataPath  // Capture for sendable closure

    return await Task.detached(priority: .userInitiated) {
      // Build list of (sessionId, filePath) to read
      var filesToRead: [(sessionId: String, filePath: String)] = []
      for (sessionId, entries) in sessionEntries {
        guard let firstEntry = entries.first else { continue }
        let encodedPath = firstEntry.project.replacingOccurrences(of: "/", with: "-")
        let filePath = "\(claudePath)/projects/\(encodedPath)/\(sessionId).jsonl"
        filesToRead.append((sessionId, filePath))
      }

      // Read all files in parallel using withTaskGroup
      return await withTaskGroup(of: (String, String?).self) { group in
        for (sessionId, filePath) in filesToRead {
          group.addTask {
            // Read only first few KB to find gitBranch (it's in early lines)
            guard let handle = FileHandle(forReadingAtPath: filePath) else {
              return (sessionId, nil)
            }
            defer { try? handle.close() }

            // Read first 4KB - gitBranch is typically in first message
            guard let data = try? handle.read(upToCount: 4096),
                  let content = String(data: data, encoding: .utf8) else {
              return (sessionId, nil)
            }

            // Parse lines looking for gitBranch
            for line in content.components(separatedBy: .newlines) {
              guard !line.isEmpty,
                    let jsonData = line.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                    let gitBranch = json["gitBranch"] as? String else {
                continue
              }
              return (sessionId, gitBranch)
            }
            return (sessionId, nil)
          }
        }

        var results: [String: String] = [:]
        for await (sessionId, branch) in group {
          if let branch = branch {
            results[sessionId] = branch
          }
        }
        return results
      }
    }.value
  }

  // MARK: - Filtered History Parsing

  /// Parses history.jsonl and filters to only entries matching selected paths
  /// Uses Task.detached to run heavy I/O and parsing off the actor's isolation context
  private func parseHistoryForPaths(_ paths: Set<String>) async -> [HistoryEntry] {
    let historyPath = claudeDataPath + "/history.jsonl"

    return await Task.detached(priority: .userInitiated) {
      guard let data = FileManager.default.contents(atPath: historyPath),
            let content = String(data: data, encoding: .utf8) else {
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

          // Only include entries that match a selected path
          let matchesPath = paths.contains { path in
            entry.project.hasPrefix(path) || entry.project == path
          }

          return matchesPath ? entry : nil
        }
    }.value
  }

}
