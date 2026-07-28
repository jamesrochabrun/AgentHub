//
//  GitWorktreeDetector.swift
//  AgentHub
//
//  Created by Assistant on 2025-09-25.
//

import Foundation
import os

/// Information about a git worktree or repository
public struct GitWorktreeInfo: Sendable {
  /// The working directory path
  public let path: String
  /// The current branch name
  public let branch: String?
  /// Whether this is a worktree (true) or main repository (false)
  public let isWorktree: Bool
  /// The main repository path (for worktrees)
  public let mainRepoPath: String?

  public init(
    path: String,
    branch: String? = nil,
    isWorktree: Bool = false,
    mainRepoPath: String? = nil
  ) {
    self.path = path
    self.branch = branch
    self.isWorktree = isWorktree
    self.mainRepoPath = mainRepoPath
  }
}

/// Utility for detecting and analyzing git worktrees
public class GitWorktreeDetector {
  /// Maximum time to wait for git commands (in seconds)
  private static let gitCommandTimeout: TimeInterval = 3.0

  /// Detects git worktree information for the given directory
  public static func detectWorktreeInfo(for directoryPath: String) async -> GitWorktreeInfo? {
    let start = ContinuousClock.now
    AppLogger.git.info("[WorktreeDetector] detectWorktreeInfo start path=\(directoryPath, privacy: .public)")
    let fileManager = FileManager.default

    // Check if .git exists
    let gitPath = (directoryPath as NSString).appendingPathComponent(".git")

    guard fileManager.fileExists(atPath: gitPath) else {
      // No .git, not a git repository
      let elapsed = ContinuousClock.now - start
      AppLogger.git.info("[WorktreeDetector] detectWorktreeInfo end path=\(directoryPath, privacy: .public) result=nil (no .git) elapsed=\(elapsed, privacy: .public)")
      return nil
    }

    // Check if .git is a file (worktree) or directory (main repo)
    var isDirectory: ObjCBool = false
    fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory)

    let isWorktree = !isDirectory.boolValue

    // Get the current branch
    let branch = await getCurrentBranch(at: directoryPath)

    if isWorktree {
      // Parse the .git file to get the main repo path
      let mainRepoPath = parseWorktreeGitFile(at: gitPath)
      let elapsed = ContinuousClock.now - start
      AppLogger.git.info("[WorktreeDetector] detectWorktreeInfo end path=\(directoryPath, privacy: .public) isWorktree=true branch=\(branch ?? "nil", privacy: .public) elapsed=\(elapsed, privacy: .public)")
      return GitWorktreeInfo(
        path: directoryPath,
        branch: branch,
        isWorktree: true,
        mainRepoPath: mainRepoPath
      )
    } else {
      // This is the main repository
      let elapsed = ContinuousClock.now - start
      AppLogger.git.info("[WorktreeDetector] detectWorktreeInfo end path=\(directoryPath, privacy: .public) isWorktree=false branch=\(branch ?? "nil", privacy: .public) elapsed=\(elapsed, privacy: .public)")
      return GitWorktreeInfo(
        path: directoryPath,
        branch: branch,
        isWorktree: false,
        mainRepoPath: nil
      )
    }
  }

  /// Gets the current branch name for the given directory
  private static func getCurrentBranch(at path: String) async -> String? {
    AppLogger.git.info("[WorktreeDetector] getCurrentBranch start path=\(path, privacy: .public)")
    guard let output = await runGitCommand(arguments: ["branch", "--show-current"], at: path) else {
      return nil
    }
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Runs a short git command and returns its stdout, or nil on launch
  /// failure or timeout.
  private static func runGitCommand(arguments: [String], at path: String) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice

    // The exit notifier must be wired BEFORE run(): these git commands exit in
    // milliseconds, and a terminationHandler installed after the exit never
    // fires, stranding the wait (and the pipe descriptors) forever.
    let exitNotifier = GitProcessExitNotifier()
    process.terminationHandler = { process in
      exitNotifier.complete(status: process.terminationStatus)
    }

    do {
      try process.run()
    } catch {
      return nil
    }

    // Drain stdout while the process runs so a full pipe can never block exit.
    async let outputData = readHandleToEnd(outputPipe.fileHandleForReading)

    let timedOut = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        _ = await exitNotifier.wait()
        return false
      }

      group.addTask {
        do {
          try await Task.sleep(for: .seconds(Self.gitCommandTimeout))
          if process.isRunning {
            process.terminate()
            AppLogger.git.warning(
              "Git command timed out args=\(arguments.joined(separator: " "), privacy: .public)"
            )
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

    let data = await outputData
    if timedOut {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private static func readHandleToEnd(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let data = handle.readDataToEndOfFile()
        continuation.resume(returning: data)
      }
    }
  }

  /// Parses the .git file in a worktree to extract the main repository path
  /// Cheaply resolves the main repository path for a worktree by reading its
  /// `.git` file (no `git` process is spawned). Returns `nil` when
  /// `directoryPath` is a regular repository (its `.git` is a directory) or the
  /// file cannot be parsed.
  public static func mainRepoPath(forWorktreeAt directoryPath: String) -> String? {
    let gitPath = (directoryPath as NSString).appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return nil
    }
    return parseWorktreeGitFile(at: gitPath)
  }

  private static func parseWorktreeGitFile(at gitFilePath: String) -> String? {
    guard let contents = try? String(contentsOfFile: gitFilePath, encoding: .utf8) else {
      return nil
    }

    // The .git file in a worktree contains: "gitdir: /path/to/main/repo/.git/worktrees/worktree-name"
    let lines = contents.components(separatedBy: .newlines)
    for line in lines {
      if line.hasPrefix("gitdir:") {
        let gitDirPath = line
          .replacingOccurrences(of: "gitdir:", with: "")
          .trimmingCharacters(in: .whitespaces)

        // Extract the main repo path from the worktree git directory
        // Format: /path/to/repo/.git/worktrees/worktree-name
        if let range = gitDirPath.range(of: "/.git/worktrees/") {
          return String(gitDirPath[..<range.lowerBound])
        }
      }
    }

    return nil
  }

  /// Lists all worktrees for a repository
  public static func listWorktrees(at repoPath: String) async -> [GitWorktreeInfo] {
    let start = ContinuousClock.now
    AppLogger.git.info("[WorktreeDetector] listWorktrees start path=\(repoPath, privacy: .public)")

    guard let output = await runGitCommand(arguments: ["worktree", "list", "--porcelain"], at: repoPath) else {
      let elapsed = ContinuousClock.now - start
      AppLogger.git.info("[WorktreeDetector] listWorktrees end path=\(repoPath, privacy: .public) result=[] (timeout or error) elapsed=\(elapsed, privacy: .public)")
      return []
    }

    let result = parseWorktreeList(output, mainRepoPath: repoPath)
    let elapsed = ContinuousClock.now - start
    AppLogger.git.info("[WorktreeDetector] listWorktrees end path=\(repoPath, privacy: .public) count=\(result.count) elapsed=\(elapsed, privacy: .public)")
    return result
  }

  /// Parses the output of `git worktree list --porcelain`
  /// Note: git worktree list always returns the main worktree first
  private static func parseWorktreeList(_ output: String, mainRepoPath: String) -> [GitWorktreeInfo] {
    var worktrees: [GitWorktreeInfo] = []
    var currentPath: String?
    var currentBranch: String?
    var isFirstWorktree = true  // First entry is always the main worktree
    var actualMainRepoPath: String?

    let lines = output.components(separatedBy: .newlines)

    for line in lines {
      if line.hasPrefix("worktree ") {
        // Save previous worktree if exists
        if let path = currentPath {
          let isMainRepo = isFirstWorktree
          if isMainRepo {
            actualMainRepoPath = path
          }
          worktrees.append(GitWorktreeInfo(
            path: path,
            branch: currentBranch,
            isWorktree: !isMainRepo,
            mainRepoPath: isMainRepo ? nil : actualMainRepoPath
          ))
          isFirstWorktree = false
        }

        // Start new worktree
        currentPath = String(line.dropFirst("worktree ".count))
        currentBranch = nil
      } else if line.hasPrefix("branch refs/heads/") {
        currentBranch = String(line.dropFirst("branch refs/heads/".count))
      }
    }

    // Add the last worktree
    if let path = currentPath {
      let isMainRepo = isFirstWorktree
      if isMainRepo {
        actualMainRepoPath = path
      }
      worktrees.append(GitWorktreeInfo(
        path: path,
        branch: currentBranch,
        isWorktree: !isMainRepo,
        mainRepoPath: isMainRepo ? nil : actualMainRepoPath
      ))
    }

    return worktrees
  }

  /// Validates that a worktree still exists
  public static func validateWorktree(at path: String) -> Bool {
    let fileManager = FileManager.default
    let gitPath = (path as NSString).appendingPathComponent(".git")
    return fileManager.fileExists(atPath: gitPath)
  }
}

/// Latches a process exit so waiters registered before OR after the exit both
/// resume. A raw terminationHandler-in-continuation cannot make that
/// guarantee, which previously stranded task groups when git exited quickly.
private final class GitProcessExitNotifier: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32?
  private var continuations: [CheckedContinuation<Int32, Never>] = []

  func complete(status: Int32) {
    lock.lock()
    if self.status == nil {
      self.status = status
    }
    let continuations = self.continuations
    self.continuations = []
    lock.unlock()

    for continuation in continuations {
      continuation.resume(returning: status)
    }
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let status {
        lock.unlock()
        continuation.resume(returning: status)
      } else {
        continuations.append(continuation)
        lock.unlock()
      }
    }
  }
}
