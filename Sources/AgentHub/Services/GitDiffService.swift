//
//  GitDiffService.swift
//  AgentHub
//
//  Created by Assistant on 1/19/26.
//

import Foundation

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

  public init() {
    print("[GitDiffService] Initialized")
  }

  // MARK: - Public API

  /// Gets all unstaged changes for a repository
  /// - Parameter repoPath: Path to the git repository (or any subdirectory)
  /// - Returns: GitDiffState containing all files with unstaged changes
  public func getUnstagedChanges(at repoPath: String) async throws -> GitDiffState {
    print("[GitDiffService] getUnstagedChanges called for: \(repoPath)")

    // Find git root
    let gitRoot = try await findGitRoot(at: repoPath)
    print("[GitDiffService] Using git root: \(gitRoot)")

    // Get unstaged changes with --numstat
    let output = try await runGitCommand(["diff", "--numstat"], at: gitRoot)

    // Also get untracked files
    let untrackedOutput = try await runGitCommand(["status", "--porcelain", "-uall"], at: gitRoot)

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

    // Parse untracked files from porcelain output
    let untrackedLines = untrackedOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
    for line in untrackedLines {
      // Format: "XY filename" where XY is status code
      guard line.count > 3 else { continue }

      let statusCode = String(line.prefix(2))
      let filePath = String(line.dropFirst(3))

      // "??" means untracked file, "A " means staged new file
      if statusCode == "??" {
        let fullPath = (gitRoot as NSString).appendingPathComponent(filePath)

        // Check if we already have this file from diff output
        if !files.contains(where: { $0.relativePath == filePath }) {
          // Count lines in untracked file
          let lineCount = await countLinesInFile(at: fullPath)

          files.append(GitDiffFileEntry(
            filePath: fullPath,
            relativePath: filePath,
            additions: lineCount,
            deletions: 0
          ))
        }
      }
    }

    print("[GitDiffService] Found \(files.count) files with changes")
    return GitDiffState(files: files)
  }

  /// Gets the diff content for a specific file (old content from HEAD, new content from disk)
  /// - Parameters:
  ///   - filePath: Absolute path to the file
  ///   - repoPath: Path to the git repository
  /// - Returns: Tuple of (oldContent, newContent)
  public func getFileDiff(filePath: String, at repoPath: String) async throws -> (oldContent: String, newContent: String) {
    print("[GitDiffService] getFileDiff called for: \(filePath)")

    let gitRoot = try await findGitRoot(at: repoPath)

    // Get relative path from git root
    let relativePath: String
    if filePath.hasPrefix(gitRoot) {
      relativePath = String(filePath.dropFirst(gitRoot.count + 1)) // +1 for trailing slash
    } else {
      relativePath = filePath
    }

    print("[GitDiffService] Relative path: \(relativePath)")

    // Get old content from HEAD
    var oldContent = ""
    do {
      oldContent = try await runGitCommand(["show", "HEAD:\(relativePath)"], at: gitRoot)
    } catch {
      // File might be new (untracked), so old content is empty
      print("[GitDiffService] Could not get HEAD content (file may be new): \(error)")
    }

    // Get new content from disk
    var newContent = ""
    let fileURL = URL(fileURLWithPath: filePath)
    if FileManager.default.fileExists(atPath: filePath) {
      do {
        newContent = try String(contentsOf: fileURL, encoding: .utf8)
      } catch {
        print("[GitDiffService] Could not read file from disk: \(error)")
        throw GitDiffError.fileNotFound(filePath)
      }
    } else {
      // File might have been deleted
      print("[GitDiffService] File does not exist on disk (may be deleted)")
    }

    return (oldContent, newContent)
  }

  // MARK: - Git Root Detection

  /// Finds the git root directory from any path within a repository
  private func findGitRoot(at path: String) async throws -> String {
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
    print("[GitDiffService] runGitCommand: git \(arguments.joined(separator: " ")) at \(path)")

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
      print("[GitDiffService] Failed to start process: \(error)")
      throw GitDiffError.gitCommandFailed("Failed to start git: \(error.localizedDescription)")
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
            print("[GitDiffService] Command timed out after \(timeout)s, terminating")
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

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

    print("[GitDiffService] Exit status: \(process.terminationStatus)")

    if didTimeout {
      throw GitDiffError.timeout
    }

    if process.terminationStatus != 0 {
      throw GitDiffError.gitCommandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return output
  }
}
