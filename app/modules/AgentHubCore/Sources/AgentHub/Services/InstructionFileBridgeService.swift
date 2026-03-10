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
  /// Safe to call multiple times — existing managed bridges are reconciled on each pass.
  func bridgeDirectories(_ paths: [String]) async

  /// Reconcile bridges to match the exact set of monitored directory paths.
  /// Managed bridges outside this set are removed.
  func reconcileDirectories(_ paths: [String]) async

  /// Remove bridges for one directory (called on repo/worktree removal).
  func removeBridges(for directoryPath: String) async

  /// Remove ALL created symlinks. Call on app exit.
  func cleanupAll() async
}

// MARK: - InstructionFileBridgeService

public actor InstructionFileBridgeService: InstructionFileBridgeServiceProtocol {

  private struct ManagedBridge: Sendable {
    let symlinkPath: String
    let target: String
    let directoryPath: String

    var sourcePath: String {
      directoryPath + "/" + target
    }

    var symlinkName: String {
      URL(fileURLWithPath: symlinkPath).lastPathComponent
    }
  }

  private let gitExcludeMarker = "# AgentHub instruction file bridge"
  private var managedBridges: [String: ManagedBridge] = [:]

  public init() {}

  // MARK: - Public API

  public func bridgeDirectories(_ paths: [String]) async {
    for path in Set(paths) {
      reconcileDirectory(path)
    }
  }

  public func reconcileDirectories(_ paths: [String]) async {
    let directoryPaths = Set(paths)
    let staleBridges = managedBridges.values.filter { !directoryPaths.contains($0.directoryPath) }
    for bridge in staleBridges {
      removeManagedBridge(bridge)
    }

    for path in directoryPaths {
      reconcileDirectory(path)
    }
  }

  public func removeBridges(for directoryPath: String) async {
    let bridgesToRemove = managedBridges.values.filter { $0.directoryPath == directoryPath }
    for bridge in bridgesToRemove {
      removeManagedBridge(bridge)
    }
  }

  public func cleanupAll() async {
    for bridge in Array(managedBridges.values) {
      removeManagedBridge(bridge)
    }
  }

  // MARK: - Private

  private func reconcileDirectory(_ dirPath: String) {
    let claudePath = dirPath + "/CLAUDE.md"
    let agentsPath = dirPath + "/AGENTS.md"

    adoptExistingBridgeIfNeeded(at: claudePath, target: "AGENTS.md", dirPath: dirPath)
    adoptExistingBridgeIfNeeded(at: agentsPath, target: "CLAUDE.md", dirPath: dirPath)

    reconcileManagedBridge(at: claudePath)
    reconcileManagedBridge(at: agentsPath)
    removeStaleExcludeIfNeeded(at: claudePath, target: "AGENTS.md", dirPath: dirPath)
    removeStaleExcludeIfNeeded(at: agentsPath, target: "CLAUDE.md", dirPath: dirPath)

    let claudeExists = bridgeSourceExists(at: claudePath)
    let agentsExists = bridgeSourceExists(at: agentsPath)
    let claudeOccupied = pathOccupied(at: claudePath)
    let agentsOccupied = pathOccupied(at: agentsPath)

    switch (claudeExists, agentsExists) {
    case (true, true), (false, false):
      return
    case (true, false):
      guard !agentsOccupied else { return }
      createSymlink(at: agentsPath, target: "CLAUDE.md", dirPath: dirPath)
    case (false, true):
      guard !claudeOccupied else { return }
      createSymlink(at: claudePath, target: "AGENTS.md", dirPath: dirPath)
    }
  }

  private func createSymlink(at symlinkPath: String, target: String, dirPath: String) {
    let fm = FileManager.default
    let bridge = ManagedBridge(symlinkPath: symlinkPath, target: target, directoryPath: dirPath)

    guard !pathOccupied(at: symlinkPath) else {
      AppLogger.bridge.info("Skipping bridge at \(symlinkPath): destination already exists")
      return
    }

    do {
      try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: target)
      AppLogger.bridge.info("Created symlink: \(symlinkPath) -> \(target)")
      managedBridges[symlinkPath] = bridge
      registerGitExclude(symlinkName: bridge.symlinkName, dirPath: dirPath)
    } catch {
      AppLogger.bridge.warning("Failed to create symlink at \(symlinkPath): \(error.localizedDescription)")
    }
  }

  private func reconcileManagedBridge(at path: String) {
    guard let bridge = managedBridges[path] else { return }

    if symlinkDestination(at: bridge.symlinkPath) == bridge.target {
      guard bridgeSourceExists(at: bridge.sourcePath) else {
        removeManagedBridge(bridge)
        return
      }

      registerGitExclude(symlinkName: bridge.symlinkName, dirPath: bridge.directoryPath)
      return
    }

    managedBridges.removeValue(forKey: bridge.symlinkPath)
    unregisterGitExclude(symlinkName: bridge.symlinkName, dirPath: bridge.directoryPath)
    AppLogger.bridge.info("Stopped managing bridge at \(bridge.symlinkPath): destination changed")
  }

  private func adoptExistingBridgeIfNeeded(at symlinkPath: String, target: String, dirPath: String) {
    guard managedBridges[symlinkPath] == nil else { return }
    guard symlinkDestination(at: symlinkPath) == target else { return }
    guard gitExcludeContainsEntry(symlinkName: URL(fileURLWithPath: symlinkPath).lastPathComponent, dirPath: dirPath) else {
      return
    }

    managedBridges[symlinkPath] = ManagedBridge(
      symlinkPath: symlinkPath,
      target: target,
      directoryPath: dirPath
    )
    AppLogger.bridge.info("Adopted existing bridge at \(symlinkPath)")
  }

  private func removeStaleExcludeIfNeeded(at symlinkPath: String, target: String, dirPath: String) {
    guard managedBridges[symlinkPath] == nil else { return }

    let symlinkName = URL(fileURLWithPath: symlinkPath).lastPathComponent
    guard gitExcludeContainsEntry(symlinkName: symlinkName, dirPath: dirPath) else { return }
    guard symlinkDestination(at: symlinkPath) != target else { return }

    unregisterGitExclude(symlinkName: symlinkName, dirPath: dirPath)
    AppLogger.bridge.info("Removed stale git exclude for \(symlinkPath)")
  }

  private func removeManagedBridge(_ bridge: ManagedBridge) {
    let fm = FileManager.default

    if symlinkDestination(at: bridge.symlinkPath) == bridge.target {
      do {
        try fm.removeItem(atPath: bridge.symlinkPath)
        AppLogger.bridge.info("Removed symlink: \(bridge.symlinkPath)")
      } catch {
        AppLogger.bridge.warning("Failed to remove symlink at \(bridge.symlinkPath): \(error.localizedDescription)")
      }
    } else {
      AppLogger.bridge.info("Managed bridge at \(bridge.symlinkPath) was replaced, leaving current item untouched")
    }

    managedBridges.removeValue(forKey: bridge.symlinkPath)
    unregisterGitExclude(symlinkName: bridge.symlinkName, dirPath: bridge.directoryPath)
  }

  private func bridgeSourceExists(at path: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
  }

  private func pathOccupied(at path: String) -> Bool {
    bridgeSourceExists(at: path) || symlinkDestination(at: path) != nil || FileManager.default.fileExists(atPath: path)
  }

  private func symlinkDestination(at path: String) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: path)
  }

  // MARK: - Git Exclude

  private func gitExcludeContainsEntry(symlinkName: String, dirPath: String) -> Bool {
    guard let excludePath = findGitExcludePath(for: dirPath),
          let content = try? String(contentsOfFile: excludePath, encoding: .utf8) else {
      return false
    }

    return excludeContainsEntry(content, pattern: "/\(symlinkName)")
  }

  private func excludeContainsEntry(_ content: String, pattern: String) -> Bool {
    let lines = content.components(separatedBy: "\n")
    for index in 0..<(lines.count - 1) where lines[index] == gitExcludeMarker && lines[index + 1] == pattern {
      return true
    }
    return false
  }

  private func unregisterGitExclude(symlinkName: String, dirPath: String) {
    guard let excludePath = findGitExcludePath(for: dirPath) else { return }
    guard let content = try? String(contentsOfFile: excludePath, encoding: .utf8) else { return }

    let pattern = "/\(symlinkName)"

    let lines = content.components(separatedBy: "\n")
    var result: [String] = []
    var i = 0
    while i < lines.count {
      if lines[i] == gitExcludeMarker, i + 1 < lines.count, lines[i + 1] == pattern {
        i += 2
      } else {
        result.append(lines[i])
        i += 1
      }
    }

    let newContent = result.joined(separator: "\n")
    try? newContent.write(toFile: excludePath, atomically: true, encoding: .utf8)
    AppLogger.bridge.info("Unregistered \(pattern) from \(excludePath)")
  }

  private func registerGitExclude(symlinkName: String, dirPath: String) {
    guard let excludePath = findGitExcludePath(for: dirPath) else { return }

    let fm = FileManager.default
    let pattern = "/\(symlinkName)"

    let existing = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
    guard !excludeContainsEntry(existing, pattern: pattern) else { return }

    let infoDir = URL(fileURLWithPath: excludePath).deletingLastPathComponent().path
    if !fm.fileExists(atPath: infoDir) {
      try? fm.createDirectory(atPath: infoDir, withIntermediateDirectories: true)
    }

    let separator = (existing.isEmpty || existing.hasSuffix("\n")) ? "" : "\n"
    let addition = "\(separator)\(gitExcludeMarker)\n\(pattern)\n"
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
