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

  // Cache for history entries to avoid re-parsing entire file
  private var historyCache: [String: [HistoryEntry]] = [:]  // sessionId -> entries
  private var lastHistoryFileSize: UInt64 = 0

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
    print("[CLIMonitorService] addRepository called for: \(path)")

    // Check if already added
    guard !selectedRepositories.contains(where: { $0.path == path }) else {
      print("[CLIMonitorService] Repository already added, returning existing")
      return selectedRepositories.first { $0.path == path }
    }

    // Detect worktrees for this repository
    print("[CLIMonitorService] Detecting worktrees...")
    let worktrees = await detectWorktrees(at: path)
    print("[CLIMonitorService] Detected \(worktrees.count) worktrees")

    let repository = SelectedRepository(
      path: path,
      worktrees: worktrees,
      isExpanded: true
    )

    selectedRepositories.append(repository)
    print("[CLIMonitorService] Repository added, now refreshing sessions...")

    // Scan for sessions in the new repository
    await refreshSessions()
    print("[CLIMonitorService] addRepository completed")

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
  public func refreshSessions() async {
    print("[CLIMonitorService] refreshSessions called")

    guard !selectedRepositories.isEmpty else {
      print("[CLIMonitorService] No repositories, sending empty")
      repositoriesSubject.send([])
      return
    }

    // Re-detect worktrees for all repositories to pick up newly created ones
    print("[CLIMonitorService] Re-detecting worktrees...")
    for index in selectedRepositories.indices {
      let repoPath = selectedRepositories[index].path
      let detectedWorktrees = await detectWorktrees(at: repoPath)

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
    print("[CLIMonitorService] Worktree re-detection complete")

    // Get all paths to filter by (including worktree paths)
    let allPaths = getAllMonitoredPaths()
    print("[CLIMonitorService] Monitoring \(allPaths.count) paths")

    // Get running processes
    print("[CLIMonitorService] Getting running processes...")
    let runningProcesses = await getRunningClaudeProcesses()
    print("[CLIMonitorService] Found \(runningProcesses.count) running processes")

    // Parse history for selected paths only
    print("[CLIMonitorService] Parsing history...")
    let historyEntries = parseHistoryForPaths(allPaths)
    print("[CLIMonitorService] Found \(historyEntries.count) history entries")

    // Group entries by session ID
    let sessionEntries = Dictionary(grouping: historyEntries) { $0.sessionId }
    print("[CLIMonitorService] Grouped into \(sessionEntries.count) sessions")

    // Build sessions and assign to worktrees
    var updatedRepositories = selectedRepositories

    for repoIndex in updatedRepositories.indices {
      for worktreeIndex in updatedRepositories[repoIndex].worktrees.indices {
        let worktreePath = updatedRepositories[repoIndex].worktrees[worktreeIndex].path

        // Find sessions for this worktree
        var sessions: [CLISession] = []

        for (sessionId, entries) in sessionEntries {
          guard let firstEntry = entries.first,
                firstEntry.project.hasPrefix(worktreePath) || firstEntry.project == worktreePath else {
            continue
          }

          // Check if session is active
          let isActive = runningProcesses.contains { process in
            process.command.contains(sessionId) || process.command.contains(firstEntry.project)
          }

          // Get the first and last message (sorted by timestamp)
          let sortedEntries = entries.sorted { $0.timestamp < $1.timestamp }
          let firstMessage = sortedEntries.first?.display
          let lastMessage = sortedEntries.last?.display

          let session = CLISession(
            id: sessionId,
            projectPath: firstEntry.project,
            branchName: updatedRepositories[repoIndex].worktrees[worktreeIndex].name,
            isWorktree: updatedRepositories[repoIndex].worktrees[worktreeIndex].isWorktree,
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
      }
    }

    selectedRepositories = updatedRepositories
    print("[CLIMonitorService] Sending \(selectedRepositories.count) repositories to subject")
    repositoriesSubject.send(selectedRepositories)
    print("[CLIMonitorService] refreshSessions completed")
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

  // MARK: - Process Detection

  private func getRunningClaudeProcesses() async -> [(pid: Int32, command: String)] {
    // TODO: Process detection disabled - sandboxing may block /bin/ps
    // For now, skip active process detection - sessions will show but not marked as "active"
    print("[CLIMonitorService] getRunningClaudeProcesses - skipping (disabled)")
    return []
  }

  // MARK: - Filtered History Parsing

  /// Parses history.jsonl and filters to only entries matching selected paths
  private func parseHistoryForPaths(_ paths: Set<String>) -> [HistoryEntry] {
    let historyPath = claudeDataPath + "/history.jsonl"

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
  }

  // MARK: - Legacy Support (for backwards compatibility)

  /// Performs a single scan for CLI sessions (legacy method)
  @available(*, deprecated, message: "Use refreshSessions() instead")
  public func scan() async -> [CLISession] {
    await refreshSessions()
    return selectedRepositories.flatMap { repo in
      repo.worktrees.flatMap { $0.sessions }
    }
  }

  /// Groups sessions by project path (legacy method)
  @available(*, deprecated, message: "Use repositoriesPublisher instead")
  public func groupSessionsByProject(_ sessions: [CLISession]) async -> [CLISessionGroup] {
    let grouped = Dictionary(grouping: sessions) { $0.projectPath }

    return grouped.map { (path, sessions) in
      CLISessionGroup(
        projectPath: path,
        sessions: sessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
      )
    }
  }
}
