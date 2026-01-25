//
//  GitHubCloneService.swift
//  AgentHub
//
//  Service for cloning GitHub repositories
//

import Foundation
import os

/// Errors that can occur during GitHub clone operations
public enum GitHubCloneServiceError: LocalizedError, Sendable {
  case directoryAlreadyExists(String)
  case cloneFailed(String)
  case invalidCloneUrl(String)
  case destinationNotWritable(String)
  case timeout

  public var errorDescription: String? {
    switch self {
    case .directoryAlreadyExists(let path):
      return "Directory already exists: \(path)"
    case .cloneFailed(let message):
      return "Clone failed: \(message)"
    case .invalidCloneUrl(let url):
      return "Invalid clone URL: \(url)"
    case .destinationNotWritable(let path):
      return "Destination is not writable: \(path)"
    case .timeout:
      return "Clone operation timed out"
    }
  }
}

/// Service for cloning GitHub repositories
public actor GitHubCloneService {

  /// Maximum time to wait for clone operation (in seconds)
  private static let cloneTimeout: TimeInterval = 600.0  // 10 minutes

  public init() { }

  // MARK: - Clone Operations

  /// Clones a repository from a URL to a destination folder
  /// - Parameters:
  ///   - cloneUrl: The git clone URL (e.g., "https://github.com/user/repo.git")
  ///   - destinationFolder: The parent folder where the repository will be cloned
  ///   - repoName: The name of the repository (used as the directory name)
  /// - Returns: The path to the cloned repository
  public func cloneRepository(
    cloneUrl: String,
    to destinationFolder: URL,
    repoName: String
  ) async throws -> URL {
    // Validate clone URL
    guard cloneUrl.hasPrefix("https://") || cloneUrl.hasPrefix("git@") else {
      throw GitHubCloneServiceError.invalidCloneUrl(cloneUrl)
    }

    // Ensure destination folder exists and is writable
    let fileManager = FileManager.default
    let destinationPath = destinationFolder.path

    if !fileManager.fileExists(atPath: destinationPath) {
      do {
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
      } catch {
        throw GitHubCloneServiceError.destinationNotWritable(destinationPath)
      }
    }

    if !fileManager.isWritableFile(atPath: destinationPath) {
      throw GitHubCloneServiceError.destinationNotWritable(destinationPath)
    }

    // Check if target directory already exists
    let targetPath = destinationFolder.appendingPathComponent(repoName)
    if fileManager.fileExists(atPath: targetPath.path) {
      throw GitHubCloneServiceError.directoryAlreadyExists(targetPath.path)
    }

    // Run git clone
    AppLogger.git.info("Cloning repository: \(cloneUrl) to \(targetPath.path)")

    try await runGitClone(cloneUrl: cloneUrl, targetPath: targetPath.path, at: destinationPath)

    AppLogger.git.info("Clone completed: \(targetPath.path)")

    return targetPath
  }

  // MARK: - Git Command Runner

  private func runGitClone(
    cloneUrl: String,
    targetPath: String,
    at workingDirectory: String
  ) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["clone", cloneUrl, targetPath]
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

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
      AppLogger.git.error("Failed to start git clone: \(error.localizedDescription)")
      throw GitHubCloneServiceError.cloneFailed("Failed to start git: \(error.localizedDescription)")
    }

    // Wait for process with timeout
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
          try await Task.sleep(for: .seconds(Self.cloneTimeout))
          if process.isRunning {
            AppLogger.git.warning("Git clone timed out after \(Self.cloneTimeout)s, terminating")
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

    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

    if didTimeout {
      throw GitHubCloneServiceError.timeout
    }

    if process.terminationStatus != 0 {
      throw GitHubCloneServiceError.cloneFailed(
        errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}
