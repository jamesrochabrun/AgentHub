//
//  InstructionFileBridgeService.swift
//  AgentHub
//
//  Bridges CLAUDE.md ↔ AGENTS.md via symlinks in project directories.
//  Symlinks are registered in .git/info/exclude (local-only) and removed on app exit.
//

import Foundation
import os

// MARK: - InstructionFileBridgeServiceProtocol

public protocol InstructionFileBridgeServiceProtocol: AnyObject, Sendable {
  /// Bridge instruction files for a set of directory paths.
  /// Safe to call multiple times — already-scanned directories are skipped.
  func bridgeDirectories(_ paths: [String]) async

  /// Remove bridges for one directory (called on repo/worktree removal).
  func removeBridges(for directoryPath: String) async

  /// Remove ALL created symlinks. Call on app exit.
  func cleanupAll() async
}

// MARK: - InstructionFileBridgeService

public actor InstructionFileBridgeService: InstructionFileBridgeServiceProtocol {

  private var createdSymlinks: Set<String> = []
  private var scannedDirectories: Set<String> = []

  public init() {}

  // MARK: - Public API

  public func bridgeDirectories(_ paths: [String]) async {
    for path in paths {
      bridgeDirectory(path)
    }
  }

  public func removeBridges(for directoryPath: String) async {
    let toRemove = createdSymlinks.filter { $0.hasPrefix(directoryPath + "/") }
    for path in toRemove {
      removeSymlink(at: path)
      createdSymlinks.remove(path)
    }
    scannedDirectories.remove(directoryPath)
  }

  public func cleanupAll() async {
    for path in createdSymlinks {
      removeSymlink(at: path)
    }
    createdSymlinks.removeAll()
    scannedDirectories.removeAll()
  }

  // MARK: - Private

  private func bridgeDirectory(_ dirPath: String) {
    guard !scannedDirectories.contains(dirPath) else { return }
    scannedDirectories.insert(dirPath)

    let fm = FileManager.default
    let claudePath = dirPath + "/CLAUDE.md"
    let agentsPath = dirPath + "/AGENTS.md"

    let claudeExists = fm.fileExists(atPath: claudePath)
    let agentsExists = fm.fileExists(atPath: agentsPath)

    switch (claudeExists, agentsExists) {
    case (true, true), (false, false):
      return
    case (true, false):
      createSymlink(at: agentsPath, target: "CLAUDE.md", dirPath: dirPath)
    case (false, true):
      createSymlink(at: claudePath, target: "AGENTS.md", dirPath: dirPath)
    }
  }

  private func createSymlink(at symlinkPath: String, target: String, dirPath: String) {
    let fm = FileManager.default

    // Remove dangling symlink left by a previous crashed session
    if (try? fm.destinationOfSymbolicLink(atPath: symlinkPath)) != nil {
      try? fm.removeItem(atPath: symlinkPath)
    }

    do {
      try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: target)
      AppLogger.bridge.info("Created symlink: \(symlinkPath) -> \(target)")
      createdSymlinks.insert(symlinkPath)
      registerGitExclude(symlinkName: URL(fileURLWithPath: symlinkPath).lastPathComponent, dirPath: dirPath)
    } catch {
      AppLogger.bridge.warning("Failed to create symlink at \(symlinkPath): \(error.localizedDescription)")
    }
  }

  private func removeSymlink(at path: String) {
    do {
      try FileManager.default.removeItem(atPath: path)
      AppLogger.bridge.info("Removed symlink: \(path)")
    } catch {
      AppLogger.bridge.warning("Failed to remove symlink at \(path): \(error.localizedDescription)")
    }
  }

  // MARK: - Git Exclude

  private func registerGitExclude(symlinkName: String, dirPath: String) {
    guard let excludePath = findGitExcludePath(for: dirPath) else { return }

    let fm = FileManager.default
    let pattern = "/\(symlinkName)"
    let marker = "# AgentHub instruction file bridge"

    let existing = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
    guard !existing.contains(pattern) else { return }

    let infoDir = URL(fileURLWithPath: excludePath).deletingLastPathComponent().path
    if !fm.fileExists(atPath: infoDir) {
      try? fm.createDirectory(atPath: infoDir, withIntermediateDirectories: true)
    }

    let separator = (existing.isEmpty || existing.hasSuffix("\n")) ? "" : "\n"
    let addition = "\(separator)\(marker)\n\(pattern)\n"
    let newContent = existing + addition

    do {
      try newContent.write(toFile: excludePath, atomically: true, encoding: .utf8)
      AppLogger.bridge.info("Registered \(pattern) in \(excludePath)")
    } catch {
      AppLogger.bridge.warning("Failed to write git exclude at \(excludePath): \(error.localizedDescription)")
    }
  }

  private func findGitExcludePath(for dirPath: String) -> String? {
    let gitPath = dirPath + "/.git"
    let fm = FileManager.default
    var isDir: ObjCBool = false

    guard fm.fileExists(atPath: gitPath, isDirectory: &isDir) else {
      return nil // Non-git directory
    }

    if isDir.boolValue {
      // Normal repo
      return gitPath + "/info/exclude"
    } else {
      // Worktree: .git is a file containing "gitdir: <path>"
      guard let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
            let range = content.range(of: "gitdir: ") else {
        return nil
      }
      let gitdirValue = String(content[range.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      // gitdirValue is e.g. /path/to/main/.git/worktrees/branchname
      // We need /path/to/main/.git/info/exclude
      let worktreeGitDir = URL(
        fileURLWithPath: gitdirValue,
        relativeTo: URL(fileURLWithPath: dirPath)
      ).standardized
      let mainGitDir = worktreeGitDir.deletingLastPathComponent().deletingLastPathComponent()
      return mainGitDir.path + "/info/exclude"
    }
  }
}
