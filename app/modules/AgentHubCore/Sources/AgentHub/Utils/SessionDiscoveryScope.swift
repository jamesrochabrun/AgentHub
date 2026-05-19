//
//  SessionDiscoveryScope.swift
//  AgentHub
//

import Foundation

struct SessionDiscoveryScope: Sendable {
  let repositoryPaths: Set<String>
  let ownedWorktreePaths: Set<String>
  let ignoredWorktreePaths: Set<String>
  let focusedSessionIds: Set<String>

  init(
    repositoryPaths: Set<String>,
    ownedWorktreePaths: Set<String>,
    ignoredWorktreePaths: Set<String>,
    focusedSessionIds: Set<String>
  ) {
    self.repositoryPaths = Self.normalizedSet(repositoryPaths)
    self.ownedWorktreePaths = Self.normalizedSet(ownedWorktreePaths)
    self.ignoredWorktreePaths = Self.normalizedSet(ignoredWorktreePaths)
    self.focusedSessionIds = focusedSessionIds
  }

  var monitoredPaths: Set<String> {
    repositoryPaths.union(ownedWorktreePaths)
  }

  func includes(projectPath: String, sessionId: String) -> Bool {
    let normalizedProjectPath = WorktreeModuleResolver.normalizedDirectoryPath(projectPath)

    if Self.path(normalizedProjectPath, isContainedInAnyOf: ownedWorktreePaths) {
      return focusedSessionIds.contains(sessionId)
    }

    if Self.path(normalizedProjectPath, isContainedInAnyOf: ignoredWorktreePaths) {
      return false
    }

    return Self.path(normalizedProjectPath, isContainedInAnyOf: repositoryPaths)
  }

  static func path(_ path: String, isContainedInAnyOf roots: Set<String>) -> Bool {
    roots.contains { root in
      path == root || path.hasPrefix(root + "/")
    }
  }

  private static func normalizedSet(_ paths: Set<String>) -> Set<String> {
    Set(paths.map { WorktreeModuleResolver.normalizedDirectoryPath($0) })
  }
}
