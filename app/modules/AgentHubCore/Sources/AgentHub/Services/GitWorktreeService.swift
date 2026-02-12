//
//  GitWorktreeService.swift
//  AgentHub
//
//  Created by Assistant on 1/12/26.
//

import Foundation
import os

/// Errors that can occur during worktree operations
public enum WorktreeCreationError: LocalizedError, Sendable {
  case directoryAlreadyExists(String)
  case invalidBranchName(String)
  case gitCommandFailed(String)
  case fetchFailed(String)
  case worktreeAlreadyExists(String)
  case timeout
  case notAGitRepository(String)

  public var errorDescription: String? {
    switch self {
    case .directoryAlreadyExists(let path):
      return "Directory already exists: \(path)"
    case .invalidBranchName(let name):
      return "Invalid branch name: \(name)"
    case .gitCommandFailed(let message):
      return "Git command failed: \(message)"
    case .fetchFailed(let message):
      return "Failed to fetch branches: \(message)"
    case .worktreeAlreadyExists(let branch):
      return "Worktree already exists for branch: \(branch)"
    case .timeout:
      return "Git command timed out"
    case .notAGitRepository(let path):
      return "Not a git repository: \(path)"
    }
  }
}

/// Result of loading local branches and current branch from a single `git branch` call.
public struct LocalBranchesResult: Sendable {
  public let branches: [RemoteBranch]
  public let currentBranchName: String
}

/// Service for creating and managing git worktrees
public actor GitWorktreeService {

  /// Maximum time to wait for quick git commands (in seconds)
  /// Local-only operations like `git branch` and `git rev-parse` complete instantly;
  /// 10s is generous while still failing faster on stuck processes.
  private static let gitCommandTimeout: TimeInterval = 10.0

  /// Maximum time to wait for slow git commands like worktree creation (in seconds)
  private static let gitWorktreeTimeout: TimeInterval = 300.0  // 5 minutes

  /// Cache for git root lookups to avoid repeated process spawns for the same path.
  /// Actor isolation provides thread safety.
  private var gitRootCache: [String: String] = [:]

  public init() { }

  // MARK: - Fetch Remote Branches

  // MARK: - Git Root Detection

  /// Finds the git root directory from any path within a repository.
  /// Results are cached so repeated calls for the same path avoid spawning a process.
  /// - Parameter path: Any path within a git repository
  /// - Returns: The root path of the git repository
  public func findGitRoot(at path: String) async throws -> String {
    if let cached = gitRootCache[path] {
      return cached
    }
    let output = try await runGitCommand(["rev-parse", "--show-toplevel"], at: path)
    let root = output.trimmingCharacters(in: .whitespacesAndNewlines)
    gitRootCache[path] = root
    return root
  }

  /// Gets all remote branches for a repository (without fetching from remote)
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: Array of remote branches
  public func getRemoteBranches(at repoPath: String) async throws -> [RemoteBranch] {
    // First, find the actual git root (handles subdirectories)
    let gitRoot: String
    do {
      gitRoot = try await findGitRoot(at: repoPath)
    } catch {
      AppLogger.git.error("Could not find git root for: \(repoPath)")
      throw WorktreeCreationError.notAGitRepository(repoPath)
    }

    // List remote branches (no network call, uses cached refs)
    let output = try await runGitCommand(["branch", "-r"], at: gitRoot)
    return parseRemoteBranches(output)
  }

  /// Fetches from all remotes and then returns branches
  /// - Parameter repoPath: Path to the git repository
  /// - Returns: Array of remote branches
  public func fetchAndGetRemoteBranches(at repoPath: String) async throws -> [RemoteBranch] {
    // First fetch all remotes (this is slow but ensures up-to-date refs)
    do {
      try await runGitCommand(["fetch", "--all"], at: repoPath)
    } catch {
      // Continue anyway - we can still list cached branches
    }

    return try await getRemoteBranches(at: repoPath)
  }

  /// Parses the output of `git branch -r`
  private func parseRemoteBranches(_ output: String) -> [RemoteBranch] {
    let lines = output.components(separatedBy: .newlines)

    return lines
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.contains("->") }  // Filter out HEAD -> origin/main
      .compactMap { line -> RemoteBranch? in
        // Format: "origin/branch-name"
        let parts = line.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return RemoteBranch(name: line, remote: String(parts[0]))
      }
      .sorted { $0.displayName < $1.displayName }
  }

  /// Gets all local branches for a repository
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: Array of local branches as RemoteBranch (with remote = "local")
  public func getLocalBranches(at repoPath: String) async throws -> [RemoteBranch] {
    let gitRoot = try await findGitRoot(at: repoPath)
    let output = try await runGitCommand(["branch"], at: gitRoot)
    return parseLocalBranches(output)
  }

  /// Parses the output of `git branch`
  private func parseLocalBranches(_ output: String) -> [RemoteBranch] {
    let lines = output.components(separatedBy: .newlines)

    return lines
      .map { line -> String in
        // Remove leading * and whitespace (current branch indicator)
        var cleaned = line.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("*") {
          cleaned = String(cleaned.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return cleaned
      }
      .filter { !$0.isEmpty }
      .map { branchName -> RemoteBranch in
        RemoteBranch(name: branchName, remote: "local")
      }
      .sorted { $0.displayName < $1.displayName }
  }

  /// Gets all local branches and the current branch name from a single `git branch` call.
  /// This avoids spawning a separate process for `git branch --show-current`.
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: A `LocalBranchesResult` with both the branch list and current branch name
  public func getLocalBranchesWithCurrent(at repoPath: String) async throws -> LocalBranchesResult {
    let gitRoot = try await findGitRoot(at: repoPath)
    let output = try await runGitCommand(["branch"], at: gitRoot)
    return parseLocalBranchesWithCurrent(output)
  }

  /// Parses the output of `git branch`, extracting both the branch list and current branch.
  /// The current branch is indicated by a leading `* ` prefix.
  /// Handles detached HEAD state (`* (HEAD detached at ...)`) by returning empty currentBranchName.
  private func parseLocalBranchesWithCurrent(_ output: String) -> LocalBranchesResult {
    let lines = output.components(separatedBy: .newlines)
    var currentBranchName = ""
    var branches: [RemoteBranch] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }

      if trimmed.hasPrefix("*") {
        let branchPart = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        // Detached HEAD looks like "* (HEAD detached at abc1234)"
        if !branchPart.hasPrefix("(") {
          currentBranchName = branchPart
          branches.append(RemoteBranch(name: branchPart, remote: "local"))
        }
      } else if trimmed.hasPrefix("+") {
        // "+" marks branches checked out in other worktrees — strip the marker
        let branchPart = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        branches.append(RemoteBranch(name: branchPart, remote: "local"))
      } else {
        branches.append(RemoteBranch(name: trimmed, remote: "local"))
      }
    }

    branches.sort { $0.displayName < $1.displayName }
    return LocalBranchesResult(branches: branches, currentBranchName: currentBranchName)
  }

  // MARK: - Progress Regex Pattern

  /// Regex pattern to match git's "Updating files: XX% (current/total)" output
  private static let updatingFilesPattern = #/Updating files:\s+\d+%\s+\((\d+)/(\d+)\)/#

  // MARK: - Create Worktree

  /// Creates a new worktree from an existing branch
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - branch: Branch name (can be remote like "origin/feature" or local)
  ///   - directoryName: Name for the new worktree directory
  /// - Returns: Path to the created worktree
  public func createWorktree(
    at repoPath: String,
    branch: String,
    directoryName: String
  ) async throws -> String {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Worktree will be created as sibling to git root
    let parentDir = (gitRoot as NSString).deletingLastPathComponent
    let worktreePath = (parentDir as NSString).appendingPathComponent(directoryName)

    // Validate directory doesn't exist
    if FileManager.default.fileExists(atPath: worktreePath) {
      throw WorktreeCreationError.directoryAlreadyExists(worktreePath)
    }

    // For remote branches (origin/xxx), extract the local branch name
    let localBranch: String
    if branch.contains("/") {
      let parts = branch.split(separator: "/", maxSplits: 1)
      localBranch = parts.count == 2 ? String(parts[1]) : branch
    } else {
      localBranch = branch
    }

    // Create worktree: git worktree add <path> <branch>
    try await runGitCommand(["worktree", "add", worktreePath, localBranch], at: gitRoot, timeout: Self.gitWorktreeTimeout)

    return worktreePath
  }

  /// Creates a new worktree with a new branch
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - newBranchName: Name for the new branch
  ///   - directoryName: Name for the new worktree directory
  ///   - startPoint: Optional starting point (defaults to HEAD)
  /// - Returns: Path to the created worktree
  public func createWorktreeWithNewBranch(
    at repoPath: String,
    newBranchName: String,
    directoryName: String,
    startPoint: String? = nil
  ) async throws -> String {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Worktree will be created as sibling to git root
    let parentDir = (gitRoot as NSString).deletingLastPathComponent
    let worktreePath = (parentDir as NSString).appendingPathComponent(directoryName)

    // Validate directory doesn't exist
    if FileManager.default.fileExists(atPath: worktreePath) {
      throw WorktreeCreationError.directoryAlreadyExists(worktreePath)
    }

    // Create worktree with new branch: git worktree add -b <branch> <path> [start-point]
    var args = ["worktree", "add", "-b", newBranchName, worktreePath]
    if let startPoint = startPoint {
      args.append(startPoint)
    }

    try await runGitCommand(args, at: gitRoot, timeout: Self.gitWorktreeTimeout)

    return worktreePath
  }

  /// Creates a new worktree with a new branch, reporting progress via callback
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - newBranchName: Name for the new branch
  ///   - directoryName: Name for the new worktree directory
  ///   - startPoint: Optional starting point (defaults to HEAD)
  ///   - onProgress: Callback for progress updates
  /// - Returns: Path to the created worktree
  public func createWorktreeWithNewBranch(
    at repoPath: String,
    newBranchName: String,
    directoryName: String,
    startPoint: String? = nil,
    onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void
  ) async throws -> String {
    // Send initial progress
    await onProgress(.preparing(message: "Preparing worktree..."))

    let gitRoot = try await findGitRoot(at: repoPath)

    // Worktree will be created as sibling to git root
    let parentDir = (gitRoot as NSString).deletingLastPathComponent
    let worktreePath = (parentDir as NSString).appendingPathComponent(directoryName)

    // Validate directory doesn't exist
    if FileManager.default.fileExists(atPath: worktreePath) {
      await onProgress(.failed(error: "Directory already exists"))
      throw WorktreeCreationError.directoryAlreadyExists(worktreePath)
    }

    // Create worktree with new branch: git worktree add -b <branch> <path> [start-point]
    var args = ["worktree", "add", "-b", newBranchName, worktreePath]
    if let startPoint = startPoint {
      args.append(startPoint)
    }

    try await runGitCommandWithProgress(args, at: gitRoot, timeout: Self.gitWorktreeTimeout, onProgress: onProgress)

    // Send completion
    await onProgress(.completed(path: worktreePath))

    return worktreePath
  }

  // MARK: - Utilities

  /// Sanitizes a branch name to create a valid directory name
  /// - Parameter branch: Branch name (e.g., "origin/feature/auth")
  /// - Returns: Sanitized directory name (e.g., "feature-auth")
  public static func sanitizeBranchName(_ branch: String) -> String {
    var name = branch

    // Remove remote prefix if present (e.g., "origin/")
    if let slashIndex = name.firstIndex(of: "/"),
       !name.hasPrefix("feature/") && !name.hasPrefix("bugfix/") && !name.hasPrefix("hotfix/") {
      // Only strip if it looks like a remote prefix (origin/, upstream/)
      let prefix = String(name[..<slashIndex])
      if prefix == "origin" || prefix == "upstream" || prefix == "remote" {
        name = String(name[name.index(after: slashIndex)...])
      }
    }

    // Replace problematic characters
    return name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
  }

  /// Creates a worktree directory name prefixed with the repository name
  /// - Parameters:
  ///   - branch: Branch name (e.g., "origin/feature/auth")
  ///   - repoName: Repository name (e.g., "apps")
  /// - Returns: Directory name (e.g., "apps-feature-auth")
  public static func worktreeDirectoryName(for branch: String, repoName: String) -> String {
    let sanitized = sanitizeBranchName(branch)
    return "\(repoName)-\(sanitized)"
  }

  // MARK: - Git Command Runner

  @discardableResult
  private func runGitCommand(
    _ arguments: [String],
    at path: String,
    timeout: TimeInterval = gitCommandTimeout
  ) async throws -> String {

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    // Prevent git from prompting for credentials/input
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"  // Disable credential prompts
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"  // Disable SSH prompts
    process.environment = environment

    // Provide empty stdin to prevent waiting for input
    let inputPipe = Pipe()
    process.standardInput = inputPipe

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      // Close stdin immediately
      try inputPipe.fileHandleForWriting.close()
    } catch {
      AppLogger.git.error("Failed to start git process: \(error.localizedDescription)")
      throw WorktreeCreationError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
    }

    // Wait for process with timeout using modern concurrency
    let didTimeout = await withTaskGroup(of: Bool.self) { group in
      // Task 1: Wait for process to complete
      group.addTask {
        await withCheckedContinuation { continuation in
          DispatchQueue.global().async {
            process.waitUntilExit()
            continuation.resume(returning: false)
          }
        }
      }

      // Task 2: Timeout
      group.addTask {
        do {
          try await Task.sleep(for: .seconds(timeout))
          if process.isRunning {
            AppLogger.git.warning("Git command timed out after \(timeout)s, terminating")
            process.terminate()
          }
          return true
        } catch {
          return false  // Task was cancelled
        }
      }

      // Return whichever finishes first
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

    // Check if process was terminated due to timeout
    if didTimeout {
      throw WorktreeCreationError.timeout
    }

    if process.terminationStatus != 0 {
      throw WorktreeCreationError.gitCommandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return output
  }

  /// Runs a git command and streams stderr for progress parsing using modern Swift concurrency
  /// - Parameters:
  ///   - arguments: Git command arguments
  ///   - path: Working directory
  ///   - timeout: Maximum time to wait
  ///   - onProgress: Callback for progress updates
  @discardableResult
  private func runGitCommandWithProgress(
    _ arguments: [String],
    at path: String,
    timeout: TimeInterval,
    onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void
  ) async throws -> String {

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    // Prevent git from prompting for credentials/input
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

    // Capture pattern for use in task
    let pattern = Self.updatingFilesPattern

    // Actor to accumulate stderr lines for error reporting (thread-safe)
    actor StderrAccumulator {
      var lines: [String] = []
      func append(_ line: String) { lines.append(line) }
      func getAll() -> String { lines.joined(separator: "\n") }
    }
    let stderrAccumulator = StderrAccumulator()

    // Use task group for proper async handling
    let (exitCode, didTimeout) = try await withThrowingTaskGroup(of: (Int32, Bool).self) { group in
      // Task 1: Run process and wait for termination
      group.addTask {
        try process.run()
        try inputPipe.fileHandleForWriting.close()

        // Use terminationHandler with continuation for proper async handling
        let exitCode = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
          process.terminationHandler = { proc in
            continuation.resume(returning: proc.terminationStatus)
          }
        }
        return (exitCode, false)
      }

      // Task 2: Read stderr and parse progress using AsyncStream
      group.addTask {
        for try await line in errorPipe.fileHandleForReading.bytes.lines {
          await stderrAccumulator.append(line)

          if let match = line.firstMatch(of: pattern),
             let current = Int(match.1),
             let total = Int(match.2) {
            await onProgress(.updatingFiles(current: current, total: total))
          } else if line.contains("Preparing worktree") {
            await onProgress(.preparing(message: "Preparing worktree..."))
          }
        }
        return (Int32(-1), false) // Sentinel value
      }

      // Task 3: Timeout
      group.addTask {
        do {
          try await Task.sleep(for: .seconds(timeout))
          if process.isRunning {
            AppLogger.git.warning("Git command timed out after \(timeout)s, terminating")
            process.terminate()
          }
          return (Int32(-1), true)
        } catch {
          return (Int32(-1), false) // Task was cancelled
        }
      }

      // Wait for process to complete or timeout
      var result: (Int32, Bool) = (0, false)
      for try await taskResult in group {
        if taskResult.1 { // Timeout
          result = taskResult
          group.cancelAll()
          break
        } else if taskResult.0 >= 0 { // Process completed (valid exit code)
          result = taskResult
          group.cancelAll()
          break
        }
      }
      return result
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""

    if didTimeout {
      throw WorktreeCreationError.timeout
    }

    if exitCode != 0 {
      // Use accumulated stderr instead of trying to read the pipe again (which would be empty)
      let errorOutput = await stderrAccumulator.getAll()
      throw WorktreeCreationError.gitCommandFailed(
        errorOutput.isEmpty ? "Git command failed with exit code \(exitCode)" : errorOutput
      )
    }

    return output
  }

  // MARK: - Git Status Helpers

  /// Returns the current branch name at the given path
  /// - Parameter repoPath: The path to the git repository
  /// - Returns: The current branch name, or empty string if in detached HEAD state
  public func getCurrentBranch(at repoPath: String) async throws -> String {
    let output = try await runGitCommand(["branch", "--show-current"], at: repoPath)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Fast path to get the current branch by reading `.git/HEAD` directly, avoiding a process spawn.
  /// Handles worktrees where `.git` is a file containing `gitdir: <path>`.
  /// Falls back to process-based `getCurrentBranch()` if file read fails.
  /// - Parameter repoPath: The path to the git repository
  /// - Returns: The current branch name, or empty string if in detached HEAD state
  public func getCurrentBranchFast(at repoPath: String) async throws -> String {
    let gitPath = (repoPath as NSString).appendingPathComponent(".git")

    var headFilePath: String
    var isDirectory: ObjCBool = false

    if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
      if isDirectory.boolValue {
        // Normal repo: .git is a directory
        headFilePath = (gitPath as NSString).appendingPathComponent("HEAD")
      } else {
        // Worktree: .git is a file with "gitdir: <path>"
        guard let contents = try? String(contentsOfFile: gitPath, encoding: .utf8),
              let gitdirLine = contents.components(separatedBy: .newlines).first(where: { $0.hasPrefix("gitdir:") }) else {
          return try await getCurrentBranch(at: repoPath)
        }
        let gitdirPath = gitdirLine
          .replacingOccurrences(of: "gitdir:", with: "")
          .trimmingCharacters(in: .whitespaces)

        // Resolve relative paths
        let resolvedGitdir: String
        if gitdirPath.hasPrefix("/") {
          resolvedGitdir = gitdirPath
        } else {
          resolvedGitdir = (repoPath as NSString).appendingPathComponent(gitdirPath)
        }
        headFilePath = (resolvedGitdir as NSString).appendingPathComponent("HEAD")
      }
    } else {
      return try await getCurrentBranch(at: repoPath)
    }

    // Read HEAD file
    guard let headContents = try? String(contentsOfFile: headFilePath, encoding: .utf8) else {
      return try await getCurrentBranch(at: repoPath)
    }

    let head = headContents.trimmingCharacters(in: .whitespacesAndNewlines)

    // HEAD contains "ref: refs/heads/<branch>" when on a branch
    if head.hasPrefix("ref: refs/heads/") {
      return String(head.dropFirst("ref: refs/heads/".count))
    }

    // Detached HEAD (SHA) or unexpected format
    return ""
  }

  /// Returns true if there are uncommitted changes (staged or unstaged)
  /// - Parameter repoPath: The path to the git repository
  /// - Returns: True if there are uncommitted changes
  public func hasUncommittedChanges(at repoPath: String) async throws -> Bool {
    let output = try await runGitCommand(["status", "--porcelain"], at: repoPath)
    return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  // MARK: - Worktree Removal

  /// Removes a worktree and its associated branch
  /// - Parameter worktreePath: Path to the worktree to remove
  public func removeWorktree(at worktreePath: String) async throws {
    let gitRoot = try await findGitRoot(at: worktreePath)
    try await runGitCommand(["worktree", "remove", worktreePath, "--force"], at: gitRoot)
  }

  // MARK: - Orphaned Worktree Handling

  /// Checks if a worktree is orphaned (directory exists but git doesn't recognize it)
  /// - Parameter worktreePath: Path to check
  /// - Returns: Tuple of (isOrphaned, parentRepoPath) if orphaned, nil otherwise
  public nonisolated func checkIfOrphaned(at worktreePath: String) -> (isOrphaned: Bool, parentRepoPath: String?)? {
    let gitFile = (worktreePath as NSString).appendingPathComponent(".git")

    // Must have .git file (not directory) to be a worktree
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gitFile, isDirectory: &isDirectory),
          !isDirectory.boolValue else {
      return nil
    }

    // Parse the .git file to get parent repo path
    guard let contents = try? String(contentsOfFile: gitFile, encoding: .utf8),
          let gitdirLine = contents.components(separatedBy: .newlines).first(where: { $0.hasPrefix("gitdir:") }) else {
      return nil
    }

    let gitdirPath = gitdirLine
      .replacingOccurrences(of: "gitdir:", with: "")
      .trimmingCharacters(in: .whitespaces)

    // Extract parent repo path: /repo/.git/worktrees/name -> /repo
    if let range = gitdirPath.range(of: "/.git/worktrees/") {
      let parentRepoPath = String(gitdirPath[..<range.lowerBound])

      // Check if the worktree metadata exists
      let metadataExists = FileManager.default.fileExists(atPath: gitdirPath)

      return (isOrphaned: !metadataExists, parentRepoPath: parentRepoPath)
    }

    return nil
  }

  /// Removes an orphaned worktree by pruning stale references and deleting the directory
  /// - Parameters:
  ///   - worktreePath: Path to the orphaned worktree directory
  ///   - parentRepoPath: Path to the parent git repository
  public func removeOrphanedWorktree(at worktreePath: String, parentRepoPath: String) async throws {
    // First, prune stale worktree references in the parent repo
    try await runGitCommand(["worktree", "prune"], at: parentRepoPath)

    // Then delete the orphaned directory
    guard FileManager.default.fileExists(atPath: worktreePath) else {
      return // Already deleted
    }
    try FileManager.default.removeItem(atPath: worktreePath)
  }
}
