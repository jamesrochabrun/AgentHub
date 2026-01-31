//
//  GitDiffService.swift
//  AgentHub
//
//  Created by Assistant on 1/19/26.
//

import Foundation
import os

/// Errors that can occur during git diff operations
public enum GitDiffError: LocalizedError, Sendable {
  case gitCommandFailed(String)
  case fileNotFound(String)
  case notAGitRepository(String)
  case timeout
  case binaryFile(String)

  public var errorDescription: String? {
    switch self {
    case .gitCommandFailed(let message):
      return "Git command failed: \(message)"
    case .fileNotFound(let path):
      return "File not found: \(path)"
    case .notAGitRepository(let path):
      return "Not a git repository: \(path)"
    case .timeout:
      return "Git command timed out"
    case .binaryFile(let path):
      return "Binary file: \(path)"
    }
  }
}

/// Service for git diff operations
public actor GitDiffService {

  /// Maximum time to wait for git commands (in seconds)
  private static let gitCommandTimeout: TimeInterval = 30.0

  public init() { }

  // MARK: - Public API

  // MARK: - Mode-Aware API

  /// Gets changes based on the specified diff mode
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - mode: The type of diff to retrieve
  ///   - baseBranch: Base branch for branch mode (auto-detected if nil)
  /// - Returns: GitDiffState containing all files with changes
  public func getChanges(
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String? = nil
  ) async throws -> GitDiffState {
    switch mode {
    case .unstaged:
      return try await getUnstagedChanges(at: repoPath)
    case .staged:
      return try await getStagedChanges(at: repoPath)
    case .branch:
      let branch: String
      if let providedBranch = baseBranch {
        branch = providedBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      return try await getBranchChanges(at: repoPath, baseBranch: branch)
    }
  }

  /// Gets all unstaged changes for a repository
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: GitDiffState containing all files with unstaged changes
  public func getUnstagedChanges(at repoPath: String) async throws -> GitDiffState {
    // Find git root
    let gitRoot = try await findGitRoot(at: repoPath)

    // Run diff and status commands in parallel
    async let numstatTask = runGitCommand(["diff", "--numstat"], at: gitRoot)
    async let porcelainTask = runGitCommand(["status", "--porcelain", "-uall"], at: gitRoot)
    let (output, untrackedOutput) = try await (numstatTask, porcelainTask)

    var files: [GitDiffFileEntry] = []

    // Parse --numstat output: "77\t7\tpath/to/file.swift"
    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in lines {
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 3 else { continue }

      // Handle binary files (shown as "-" for additions/deletions)
      let additions = Int(parts[0]) ?? 0
      let deletions = Int(parts[1]) ?? 0
      let relativePath = parts[2]

      let fullPath = (gitRoot as NSString).appendingPathComponent(relativePath)
      files.append(GitDiffFileEntry(
        filePath: fullPath,
        relativePath: relativePath,
        additions: additions,
        deletions: deletions
      ))
    }

    // Collect untracked file paths for parallel line counting
    var untrackedFilePaths: [(relativePath: String, fullPath: String)] = []

    // Parse untracked files from porcelain output
    let untrackedLines = untrackedOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in untrackedLines {
      // Format: "XY filename" where XY is status code
      guard line.count > 3 else { continue }

      let statusCode = String(line.prefix(2))
      let filePath = String(line.dropFirst(3))

      // "??" means untracked file
      if statusCode == "??" {
        let fullPath = (gitRoot as NSString).appendingPathComponent(filePath)

        // Check if we already have this file from diff output
        if !files.contains(where: { $0.relativePath == filePath }) {
          untrackedFilePaths.append((relativePath: filePath, fullPath: fullPath))
        }
      }
    }

    // Count lines in parallel for untracked files
    if !untrackedFilePaths.isEmpty {
      let untrackedEntries = await withTaskGroup(of: GitDiffFileEntry?.self) { group in
        for (relativePath, fullPath) in untrackedFilePaths {
          group.addTask {
            let lineCount = await self.countLinesInFile(at: fullPath)
            return GitDiffFileEntry(
              filePath: fullPath,
              relativePath: relativePath,
              additions: lineCount,
              deletions: 0
            )
          }
        }

        var results: [GitDiffFileEntry] = []
        for await entry in group {
          if let entry = entry {
            results.append(entry)
          }
        }
        return results
      }
      files.append(contentsOf: untrackedEntries)
    }

    return GitDiffState(files: files)
  }

  /// Gets all staged changes for a repository
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: GitDiffState containing all files with staged changes
  public func getStagedChanges(at repoPath: String) async throws -> GitDiffState {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get staged changes with --numstat --staged
    let output = try await runGitCommand(["diff", "--staged", "--numstat"], at: gitRoot)

    var files: [GitDiffFileEntry] = []

    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in lines {
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 3 else { continue }

      let additions = Int(parts[0]) ?? 0
      let deletions = Int(parts[1]) ?? 0
      let relativePath = parts[2]

      let fullPath = (gitRoot as NSString).appendingPathComponent(relativePath)
      files.append(GitDiffFileEntry(
        filePath: fullPath,
        relativePath: relativePath,
        additions: additions,
        deletions: deletions
      ))
    }

    return GitDiffState(files: files)
  }

  /// Gets all changes between current branch and base branch
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - baseBranch: The base branch to compare against (e.g., "main", "master")
  /// - Returns: GitDiffState containing all files changed since branching from base
  public func getBranchChanges(at repoPath: String, baseBranch: String) async throws -> GitDiffState {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Use three-dot diff to compare from merge-base to HEAD
    let output = try await runGitCommand(["diff", "\(baseBranch)...HEAD", "--numstat"], at: gitRoot)

    var files: [GitDiffFileEntry] = []

    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in lines {
      let parts = line.components(separatedBy: "\t")
      guard parts.count >= 3 else { continue }

      let additions = Int(parts[0]) ?? 0
      let deletions = Int(parts[1]) ?? 0
      let relativePath = parts[2]

      let fullPath = (gitRoot as NSString).appendingPathComponent(relativePath)
      files.append(GitDiffFileEntry(
        filePath: fullPath,
        relativePath: relativePath,
        additions: additions,
        deletions: deletions
      ))
    }

    return GitDiffState(files: files)
  }

  /// Detects the base branch (main or master)
  /// - Parameter repoPath: Path to the git repository
  /// - Returns: The detected base branch name
  public func detectBaseBranch(at repoPath: String) async throws -> String {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Try "main" first
    do {
      _ = try await runGitCommand(["rev-parse", "--verify", "main"], at: gitRoot)
      return "main"
    } catch {
      // Try "master" as fallback
      do {
        _ = try await runGitCommand(["rev-parse", "--verify", "master"], at: gitRoot)
        return "master"
      } catch {
        throw GitDiffError.gitCommandFailed("Could not detect base branch (tried main, master)")
      }
    }
  }

  // MARK: - Unified Diff Output (Fast Path)

  /// Gets unified diff output directly from git (fast - single command, no file content fetching)
  /// - Parameters:
  ///   - repoPath: Path to the git repository (or any subdirectory)
  ///   - mode: The type of diff to retrieve
  ///   - baseBranch: Base branch for branch mode (auto-detected if nil)
  /// - Returns: Raw unified diff output from git
  public func getUnifiedDiffOutput(
    at repoPath: String,
    mode: DiffMode,
    baseBranch: String? = nil
  ) async throws -> String {
    let gitRoot = try await findGitRoot(at: repoPath)

    let command: [String]
    switch mode {
    case .unstaged:
      command = ["diff"]
    case .staged:
      command = ["diff", "--staged"]
    case .branch:
      let branch: String
      if let providedBranch = baseBranch {
        branch = providedBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      command = ["diff", "\(branch)...HEAD"]
    }

    return try await runGitCommand(command, at: gitRoot)
  }

  /// Gets unified diff output for a specific file (fast - single command)
  /// - Parameters:
  ///   - filePath: Absolute path to the file
  ///   - repoPath: Path to the git repository
  ///   - mode: The diff mode (unstaged, staged, or branch)
  ///   - baseBranch: Base branch for branch mode (auto-detected if nil)
  /// - Returns: Raw unified diff output for the file
  public func getUnifiedFileDiff(
    filePath: String,
    at repoPath: String,
    mode: DiffMode = .unstaged,
    baseBranch: String? = nil
  ) async throws -> String {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1))
    } else {
      relativePath = filePath
    }

    let command: [String]
    switch mode {
    case .unstaged:
      command = ["diff", "--", relativePath]
    case .staged:
      command = ["diff", "--staged", "--", relativePath]
    case .branch:
      let branch: String
      if let providedBranch = baseBranch {
        branch = providedBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      command = ["diff", "\(branch)...HEAD", "--", relativePath]
    }

    return try await runGitCommand(command, at: gitRoot)
  }

  /// Gets the diff content for a specific file based on mode
  /// - Parameters:
  ///   - filePath: Absolute path to the file
  ///   - repoPath: Path to the git repository
  ///   - mode: The diff mode (unstaged, staged, or branch)
  ///   - baseBranch: Base branch for branch mode (auto-detected if nil)
  /// - Returns: Tuple of (oldContent, newContent)
  public func getFileDiff(
    filePath: String,
    at repoPath: String,
    mode: DiffMode = .unstaged,
    baseBranch: String? = nil
  ) async throws -> (oldContent: String, newContent: String) {
    switch mode {
    case .unstaged:
      return try await getUnstagedFileDiff(filePath: filePath, at: repoPath)
    case .staged:
      return try await getStagedFileDiff(filePath: filePath, at: repoPath)
    case .branch:
      let branch: String
      if let providedBranch = baseBranch {
        branch = providedBranch
      } else {
        branch = try await detectBaseBranch(at: repoPath)
      }
      return try await getBranchFileDiff(filePath: filePath, at: repoPath, baseBranch: branch)
    }
  }

  /// Gets the diff content for an unstaged file (old content from HEAD, new content from disk)
  private func getUnstagedFileDiff(filePath: String, at repoPath: String) async throws -> (oldContent: String, newContent: String) {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1)) // +1 for trailing slash
    } else {
      relativePath = filePath
    }

    // Get old content from HEAD
    var oldContent = ""
    do {
      oldContent = try await runGitCommand(["show", "HEAD:\(relativePath)"], at: gitRoot)
    } catch {
      // File might be new (untracked), so old content is empty
    }

    // Get new content from disk
    var newContent = ""
    let fileURL = URL(fileURLWithPath: filePath)
    if FileManager.default.fileExists(atPath: filePath) {
      do {
        newContent = try String(contentsOf: fileURL, encoding: .utf8)
      } catch {
        AppLogger.git.error("Could not read file from disk: \(error.localizedDescription)")
        throw GitDiffError.fileNotFound(filePath)
      }
    }

    return (oldContent, newContent)
  }

  /// Gets the diff content for a staged file (old content from HEAD, new content from index)
  private func getStagedFileDiff(filePath: String, at repoPath: String) async throws -> (oldContent: String, newContent: String) {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1))
    } else {
      relativePath = filePath
    }

    // Get old content from HEAD and new content from index in parallel
    async let oldTask = fetchGitFileContent(ref: "HEAD", relativePath: relativePath, gitRoot: gitRoot)
    async let newTask = fetchGitFileContent(ref: "", relativePath: relativePath, gitRoot: gitRoot) // empty ref = index

    let (oldContent, newContent) = await (oldTask, newTask)
    return (oldContent, newContent)
  }

  /// Gets the diff content for a branch file (old content from merge-base, new content from HEAD)
  private func getBranchFileDiff(filePath: String, at repoPath: String, baseBranch: String) async throws -> (oldContent: String, newContent: String) {
    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1))
    } else {
      relativePath = filePath
    }

    // Find the merge-base between current branch and base branch
    let mergeBaseOutput = try await runGitCommand(["merge-base", baseBranch, "HEAD"], at: gitRoot)
    let mergeBase = mergeBaseOutput.trimmingCharacters(in: .whitespacesAndNewlines)

    // Get old content from merge-base and new content from HEAD in parallel
    async let oldTask = fetchGitFileContent(ref: mergeBase, relativePath: relativePath, gitRoot: gitRoot)
    async let newTask = fetchGitFileContent(ref: "HEAD", relativePath: relativePath, gitRoot: gitRoot)

    let (oldContent, newContent) = await (oldTask, newTask)
    return (oldContent, newContent)
  }

  /// Helper to fetch file content from a git ref (or index if ref is empty)
  private func fetchGitFileContent(ref: String, relativePath: String, gitRoot: String) async -> String {
    do {
      if ref.isEmpty {
        // Empty ref means staging area (index): "git show :file"
        return try await runGitCommand(["show", ":\(relativePath)"], at: gitRoot)
      } else {
        return try await runGitCommand(["show", "\(ref):\(relativePath)"], at: gitRoot)
      }
    } catch {
      // File might be new or deleted
      return ""
    }
  }

  // MARK: - Git Root Detection

  /// Finds the git root directory from any path within a repository
  public func findGitRoot(at path: String) async throws -> String {
    let output = try await runGitCommand(["rev-parse", "--show-toplevel"], at: path)
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Helper Methods

  /// Counts lines in a file
  private func countLinesInFile(at path: String) async -> Int {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
      return 0
    }
    return content.components(separatedBy: .newlines).count
  }

  /// Runs a git command and returns the output
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

    do {
      try process.run()
      try inputPipe.fileHandleForWriting.close()
    } catch {
      AppLogger.git.error("Failed to start git process: \(error.localizedDescription)")
      throw GitDiffError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
    }

    // CRITICAL: Read stdout/stderr concurrently BEFORE waiting for process exit
    // This prevents deadlock when output is large enough to fill the pipe buffer.
    // If we wait first, the process blocks trying to write, but we're waiting for it to exit.
    var outputData: Data?
    var errorData: Data?
    let readGroup = DispatchGroup()

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      outputData = try? outputPipe.fileHandleForReading.readToEnd()
      readGroup.leave()
    }

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      errorData = try? errorPipe.fileHandleForReading.readToEnd()
      readGroup.leave()
    }

    // Wait for reads to complete with timeout
    let didTimeout = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          DispatchQueue.global().async {
            // Wait for reads first
            readGroup.wait()
            // Then wait for process to exit
            process.waitUntilExit()
            continuation.resume(returning: false)
          }
        }
      }

      group.addTask {
        do {
          try await Task.sleep(for: .seconds(timeout))
          if process.isRunning {
            AppLogger.git.warning("Git command timed out after \(timeout)s, terminating")
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

    let output = String(data: outputData ?? Data(), encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData ?? Data(), encoding: .utf8) ?? ""

    if didTimeout {
      throw GitDiffError.timeout
    }

    if process.terminationStatus != 0 {
      throw GitDiffError.gitCommandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return output
  }
}
