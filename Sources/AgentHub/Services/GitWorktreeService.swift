//
//  GitWorktreeService.swift
//  AgentHub
//
//  Created by Assistant on 1/12/26.
//

import Foundation

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

/// Service for creating and managing git worktrees
public actor GitWorktreeService {

  /// Maximum time to wait for quick git commands (in seconds)
  private static let gitCommandTimeout: TimeInterval = 30.0

  /// Maximum time to wait for slow git commands like worktree creation (in seconds)
  private static let gitWorktreeTimeout: TimeInterval = 300.0  // 5 minutes

  public init() {
    print("[GitWorktreeService] Initialized")
  }

  // MARK: - Fetch Remote Branches

  // MARK: - Git Root Detection

  /// Finds the git root directory from any path within a repository
  /// - Parameter path: Any path within a git repository
  /// - Returns: The root path of the git repository
  public func findGitRoot(at path: String) async throws -> String {
    print("[GitWorktreeService] findGitRoot called for: \(path)")

    let output = try await runGitCommand(["rev-parse", "--show-toplevel"], at: path)
    let gitRoot = output.trimmingCharacters(in: .whitespacesAndNewlines)

    print("[GitWorktreeService] Git root found: \(gitRoot)")
    return gitRoot
  }

  /// Gets all remote branches for a repository (without fetching from remote)
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: Array of remote branches
  public func getRemoteBranches(at repoPath: String) async throws -> [RemoteBranch] {
    print("[GitWorktreeService] getRemoteBranches called for: \(repoPath)")

    // First, find the actual git root (handles subdirectories)
    let gitRoot: String
    do {
      gitRoot = try await findGitRoot(at: repoPath)
      print("[GitWorktreeService] Using git root: \(gitRoot)")
    } catch {
      print("[GitWorktreeService] ERROR: Could not find git root - \(error)")
      throw WorktreeCreationError.notAGitRepository(repoPath)
    }

    // Verify it's a git repository (check for .git file or directory)
    let gitPath = (gitRoot as NSString).appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory)

    print("[GitWorktreeService] Checking .git at: \(gitPath)")
    print("[GitWorktreeService] .git exists: \(exists), isDirectory: \(isDirectory.boolValue)")

    // If .git is a file, this is a worktree - read the gitdir to find main repo
    if exists && !isDirectory.boolValue {
      print("[GitWorktreeService] This is a worktree (.git is a file)")
      if let gitFileContents = try? String(contentsOfFile: gitPath, encoding: .utf8) {
        print("[GitWorktreeService] .git file contents: \(gitFileContents)")
      }
    }

    // Check if remote is configured
    print("[GitWorktreeService] Checking remotes...")
    let remoteOutput = try await runGitCommand(["remote", "-v"], at: gitRoot)
    print("[GitWorktreeService] git remote -v output:\n\(remoteOutput)")

    if remoteOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      print("[GitWorktreeService] WARNING: No remotes configured!")
    }

    // List remote branches (no network call, uses cached refs)
    print("[GitWorktreeService] Running: git branch -r")
    let output = try await runGitCommand(["branch", "-r"], at: gitRoot)
    print("[GitWorktreeService] git branch -r output: '\(output)'")

    let branches = parseRemoteBranches(output)
    print("[GitWorktreeService] Parsed \(branches.count) remote branches")

    // If no remote branches, also try listing local branches for debugging
    if branches.isEmpty {
      print("[GitWorktreeService] No remote branches found, checking local branches...")
      let localOutput = try await runGitCommand(["branch"], at: gitRoot)
      print("[GitWorktreeService] git branch output: '\(localOutput)'")

      // Also check git status for more context
      let statusOutput = try await runGitCommand(["status", "--short"], at: gitRoot)
      print("[GitWorktreeService] git status --short: '\(statusOutput)'")
    }

    return branches
  }

  /// Fetches from all remotes and then returns branches
  /// - Parameter repoPath: Path to the git repository
  /// - Returns: Array of remote branches
  public func fetchAndGetRemoteBranches(at repoPath: String) async throws -> [RemoteBranch] {
    print("[GitWorktreeService] fetchAndGetRemoteBranches called for: \(repoPath)")

    // First fetch all remotes (this is slow but ensures up-to-date refs)
    print("[GitWorktreeService] Running: git fetch --all")
    do {
      try await runGitCommand(["fetch", "--all"], at: repoPath)
      print("[GitWorktreeService] git fetch --all completed")
    } catch {
      print("[GitWorktreeService] git fetch --all failed: \(error)")
      // Continue anyway - we can still list cached branches
    }

    return try await getRemoteBranches(at: repoPath)
  }

  /// Parses the output of `git branch -r`
  private func parseRemoteBranches(_ output: String) -> [RemoteBranch] {
    let lines = output.components(separatedBy: .newlines)
    print("[GitWorktreeService] parseRemoteBranches: \(lines.count) lines")

    let branches = lines
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.contains("->") }  // Filter out HEAD -> origin/main
      .compactMap { line -> RemoteBranch? in
        // Format: "origin/branch-name"
        let parts = line.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else {
          print("[GitWorktreeService] Skipping line (no slash): '\(line)'")
          return nil
        }
        let branch = RemoteBranch(
          name: line,
          remote: String(parts[0])
        )
        print("[GitWorktreeService] Parsed branch: \(branch.displayName) from \(branch.remote)")
        return branch
      }
      .sorted { $0.displayName < $1.displayName }

    return branches
  }

  /// Gets all local branches for a repository
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: Array of local branches as RemoteBranch (with remote = "local")
  public func getLocalBranches(at repoPath: String) async throws -> [RemoteBranch] {
    print("[GitWorktreeService] getLocalBranches called for: \(repoPath)")

    // Find actual git root
    let gitRoot = try await findGitRoot(at: repoPath)
    print("[GitWorktreeService] Using git root: \(gitRoot)")

    let output = try await runGitCommand(["branch"], at: gitRoot)
    print("[GitWorktreeService] git branch output: '\(output)'")

    return parseLocalBranches(output)
  }

  /// Parses the output of `git branch`
  private func parseLocalBranches(_ output: String) -> [RemoteBranch] {
    let lines = output.components(separatedBy: .newlines)
    print("[GitWorktreeService] parseLocalBranches: \(lines.count) lines")

    let branches = lines
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
        let branch = RemoteBranch(name: branchName, remote: "local")
        print("[GitWorktreeService] Parsed local branch: \(branch.displayName)")
        return branch
      }
      .sorted { $0.displayName < $1.displayName }

    return branches
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
    print("[GitWorktreeService] createWorktree: repo=\(repoPath), branch=\(branch), dir=\(directoryName)")

    // Find actual git root
    let gitRoot = try await findGitRoot(at: repoPath)
    print("[GitWorktreeService] Using git root: \(gitRoot)")

    // Worktree will be created as sibling to git root
    let parentDir = (gitRoot as NSString).deletingLastPathComponent
    let worktreePath = (parentDir as NSString).appendingPathComponent(directoryName)
    print("[GitWorktreeService] Worktree will be created at: \(worktreePath)")

    // Validate directory doesn't exist
    if FileManager.default.fileExists(atPath: worktreePath) {
      print("[GitWorktreeService] ERROR: Directory already exists")
      throw WorktreeCreationError.directoryAlreadyExists(worktreePath)
    }

    // For remote branches (origin/xxx), extract the local branch name
    let localBranch: String
    if branch.contains("/") {
      // Extract branch name after the remote prefix
      let parts = branch.split(separator: "/", maxSplits: 1)
      localBranch = parts.count == 2 ? String(parts[1]) : branch
      print("[GitWorktreeService] Extracted local branch name: \(localBranch)")
    } else {
      localBranch = branch
    }

    // Create worktree: git worktree add <path> <branch>
    print("[GitWorktreeService] Running: git worktree add \(worktreePath) \(localBranch)")
    try await runGitCommand(["worktree", "add", worktreePath, localBranch], at: gitRoot, timeout: Self.gitWorktreeTimeout)
    print("[GitWorktreeService] Worktree created successfully")

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
    print("[GitWorktreeService] createWorktreeWithNewBranch: repo=\(repoPath), branch=\(newBranchName), dir=\(directoryName)")

    // Find actual git root
    let gitRoot = try await findGitRoot(at: repoPath)
    print("[GitWorktreeService] Using git root: \(gitRoot)")

    // Worktree will be created as sibling to git root
    let parentDir = (gitRoot as NSString).deletingLastPathComponent
    let worktreePath = (parentDir as NSString).appendingPathComponent(directoryName)
    print("[GitWorktreeService] Worktree will be created at: \(worktreePath)")

    // Validate directory doesn't exist
    if FileManager.default.fileExists(atPath: worktreePath) {
      print("[GitWorktreeService] ERROR: Directory already exists")
      throw WorktreeCreationError.directoryAlreadyExists(worktreePath)
    }

    // Create worktree with new branch: git worktree add -b <branch> <path> [start-point]
    var args = ["worktree", "add", "-b", newBranchName, worktreePath]
    if let startPoint = startPoint {
      args.append(startPoint)
    }

    print("[GitWorktreeService] Running: git \(args.joined(separator: " "))")
    try await runGitCommand(args, at: gitRoot, timeout: Self.gitWorktreeTimeout)
    print("[GitWorktreeService] Worktree with new branch created successfully")

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
    print("[GitWorktreeService] createWorktreeWithNewBranch (with progress): repo=\(repoPath), branch=\(newBranchName), dir=\(directoryName)")

    // Send initial progress
    await onProgress(.preparing(message: "Preparing worktree..."))

    // Find actual git root
    let gitRoot = try await findGitRoot(at: repoPath)
    print("[GitWorktreeService] Using git root: \(gitRoot)")

    // Worktree will be created as sibling to git root
    let parentDir = (gitRoot as NSString).deletingLastPathComponent
    let worktreePath = (parentDir as NSString).appendingPathComponent(directoryName)
    print("[GitWorktreeService] Worktree will be created at: \(worktreePath)")

    // Validate directory doesn't exist
    if FileManager.default.fileExists(atPath: worktreePath) {
      print("[GitWorktreeService] ERROR: Directory already exists")
      await onProgress(.failed(error: "Directory already exists"))
      throw WorktreeCreationError.directoryAlreadyExists(worktreePath)
    }

    // Create worktree with new branch: git worktree add -b <branch> <path> [start-point]
    var args = ["worktree", "add", "-b", newBranchName, worktreePath]
    if let startPoint = startPoint {
      args.append(startPoint)
    }

    print("[GitWorktreeService] Running: git \(args.joined(separator: " "))")
    try await runGitCommandWithProgress(args, at: gitRoot, timeout: Self.gitWorktreeTimeout, onProgress: onProgress)
    print("[GitWorktreeService] Worktree with new branch created successfully")

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

  // MARK: - Git Command Runner

  @discardableResult
  private func runGitCommand(
    _ arguments: [String],
    at path: String,
    timeout: TimeInterval = gitCommandTimeout
  ) async throws -> String {
    print("[GitWorktreeService] runGitCommand: git \(arguments.joined(separator: " ")) at \(path) (timeout: \(timeout)s)")

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
      print("[GitWorktreeService] Failed to start process: \(error)")
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
            print("[GitWorktreeService] Command timed out after \(timeout)s, terminating")
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

    print("[GitWorktreeService] Exit status: \(process.terminationStatus), timed out: \(didTimeout)")
    if !output.isEmpty {
      print("[GitWorktreeService] stdout: \(output.prefix(500))")
    }
    if !errorOutput.isEmpty {
      print("[GitWorktreeService] stderr: \(errorOutput.prefix(500))")
    }

    // Check if process was terminated due to timeout
    if didTimeout {
      throw WorktreeCreationError.timeout
    }

    if process.terminationStatus != 0 {
      throw WorktreeCreationError.gitCommandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return output
  }

  /// Runs a git command and streams stderr for progress parsing
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
    print("[GitWorktreeService] runGitCommandWithProgress: git \(arguments.joined(separator: " ")) at \(path)")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    // Prevent git from prompting for credentials/input
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    process.environment = environment

    // Provide empty stdin to prevent waiting for input
    let inputPipe = Pipe()
    process.standardInput = inputPipe

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    // Accumulated stderr for error reporting
    actor StderrAccumulator {
      var data = Data()
      func append(_ newData: Data) {
        data.append(newData)
      }
      func getData() -> Data {
        return data
      }
    }
    let stderrAccumulator = StderrAccumulator()

    // Capture the regex pattern for use in the closure
    let pattern = Self.updatingFilesPattern

    // Set up stderr handler to parse progress
    errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }

      // Accumulate stderr data
      Task {
        await stderrAccumulator.append(data)
      }

      guard let line = String(data: data, encoding: .utf8) else { return }
      print("[GitWorktreeService] stderr chunk: \(line)")

      // Parse progress from stderr
      if let match = line.firstMatch(of: pattern) {
        if let current = Int(match.1), let total = Int(match.2) {
          Task {
            await onProgress(.updatingFiles(current: current, total: total))
          }
        }
      } else if line.contains("Preparing worktree") {
        Task {
          await onProgress(.preparing(message: "Preparing worktree..."))
        }
      }
    }

    do {
      try process.run()
      try inputPipe.fileHandleForWriting.close()
    } catch {
      errorPipe.fileHandleForReading.readabilityHandler = nil
      print("[GitWorktreeService] Failed to start process: \(error)")
      throw WorktreeCreationError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
    }

    // Wait for process with timeout
    let didTimeout = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          DispatchQueue.global().async {
            process.waitUntilExit()
            continuation.resume(returning: false)
          }
        }
      }

      group.addTask {
        do {
          try await Task.sleep(for: .seconds(timeout))
          if process.isRunning {
            print("[GitWorktreeService] Command timed out after \(timeout)s, terminating")
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

    // Clean up handler
    errorPipe.fileHandleForReading.readabilityHandler = nil

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = await stderrAccumulator.getData()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

    print("[GitWorktreeService] Exit status: \(process.terminationStatus), timed out: \(didTimeout)")

    if didTimeout {
      throw WorktreeCreationError.timeout
    }

    if process.terminationStatus != 0 {
      throw WorktreeCreationError.gitCommandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
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

  /// Returns true if there are uncommitted changes (staged or unstaged)
  /// - Parameter repoPath: The path to the git repository
  /// - Returns: True if there are uncommitted changes
  public func hasUncommittedChanges(at repoPath: String) async throws -> Bool {
    let output = try await runGitCommand(["status", "--porcelain"], at: repoPath)
    return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}
