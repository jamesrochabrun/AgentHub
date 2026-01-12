//
//  GitWorktreeDetector.swift
//  AgentHub
//
//  Created by Assistant on 2025-09-25.
//

import Foundation

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
@MainActor
public class GitWorktreeDetector {
  /// Maximum time to wait for git commands (in seconds)
  private static let gitCommandTimeout: TimeInterval = 3.0

  /// Detects git worktree information for the given directory
  public static func detectWorktreeInfo(for directoryPath: String) async -> GitWorktreeInfo? {
    let fileManager = FileManager.default

    // Check if .git exists
    let gitPath = (directoryPath as NSString).appendingPathComponent(".git")

    guard fileManager.fileExists(atPath: gitPath) else {
      // No .git, not a git repository
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
      return GitWorktreeInfo(
        path: directoryPath,
        branch: branch,
        isWorktree: true,
        mainRepoPath: mainRepoPath
      )
    } else {
      // This is the main repository
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["branch", "--show-current"]
    process.currentDirectoryURL = URL(fileURLWithPath: path)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()

      // Add timeout to prevent hanging
      let timeoutTask = Task {
        try await Task.sleep(nanoseconds: UInt64(gitCommandTimeout * 1_000_000_000))
        if process.isRunning {
          process.terminate()
          print("Git branch command timed out after \(gitCommandTimeout) seconds")
        }
      }

      process.waitUntilExit()
      timeoutTask.cancel()

      // Check if process was terminated due to timeout
      if process.terminationStatus == SIGTERM {
        return nil
      }

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)

      return output?.isEmpty == false ? output : nil
    } catch {
      return nil
    }
  }

  /// Parses the .git file in a worktree to extract the main repository path
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["worktree", "list", "--porcelain"]
    process.currentDirectoryURL = URL(fileURLWithPath: repoPath)

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()

      // Add timeout to prevent hanging
      let timeoutTask = Task {
        try await Task.sleep(nanoseconds: UInt64(gitCommandTimeout * 1_000_000_000))
        if process.isRunning {
          process.terminate()
          print("Git worktree list command timed out after \(gitCommandTimeout) seconds")
        }
      }

      process.waitUntilExit()
      timeoutTask.cancel()

      // Check if process was terminated due to timeout
      if process.terminationStatus == SIGTERM {
        print("Git worktree list timed out for path: \(repoPath)")
        return []
      }

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      guard let output = String(data: data, encoding: .utf8) else {
        return []
      }

      return parseWorktreeList(output, mainRepoPath: repoPath)
    } catch {
      return []
    }
  }

  /// Parses the output of `git worktree list --porcelain`
  private static func parseWorktreeList(_ output: String, mainRepoPath: String) -> [GitWorktreeInfo] {
    var worktrees: [GitWorktreeInfo] = []
    var currentPath: String?
    var currentBranch: String?

    let lines = output.components(separatedBy: .newlines)

    for line in lines {
      if line.hasPrefix("worktree ") {
        // Save previous worktree if exists
        if let path = currentPath {
          let isMainRepo = path == mainRepoPath
          worktrees.append(GitWorktreeInfo(
            path: path,
            branch: currentBranch,
            isWorktree: !isMainRepo,
            mainRepoPath: isMainRepo ? nil : mainRepoPath
          ))
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
      let isMainRepo = path == mainRepoPath
      worktrees.append(GitWorktreeInfo(
        path: path,
        branch: currentBranch,
        isWorktree: !isMainRepo,
        mainRepoPath: isMainRepo ? nil : mainRepoPath
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
