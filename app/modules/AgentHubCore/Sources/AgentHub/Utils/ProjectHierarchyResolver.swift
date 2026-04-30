//
//  ProjectHierarchyResolver.swift
//  AgentHub
//

import Foundation

/// Shared path rules for displaying sessions under the root repository that owns
/// their worktree.
public enum ProjectHierarchyResolver {
  public static func rootProjectPath(
    for projectPath: String,
    repositories: [SelectedRepository]
  ) -> String {
    let normalizedProjectPath = normalize(projectPath)
    var bestMatch: (rootPath: String, matchedLength: Int)?

    for repository in repositories {
      let normalizedRepositoryPath = normalize(repository.path)
      if isSameOrDescendant(normalizedProjectPath, ofNormalizedRoot: normalizedRepositoryPath) {
        bestMatch = chooseBetterMatch(
          current: bestMatch,
          candidate: (rootPath: repository.path, matchedLength: normalizedRepositoryPath.count)
        )
      }

      for worktree in repository.worktrees {
        let normalizedWorktreePath = normalize(worktree.path)
        if isSameOrDescendant(normalizedProjectPath, ofNormalizedRoot: normalizedWorktreePath) {
          bestMatch = chooseBetterMatch(
            current: bestMatch,
            candidate: (rootPath: repository.path, matchedLength: normalizedWorktreePath.count)
          )
        }
      }
    }

    return bestMatch?.rootPath ?? projectPath
  }

  public static func rootRepositoryPath(
    for requestedPath: String,
    worktrees: [WorktreeBranch]
  ) -> String {
    worktrees.first(where: { !$0.isWorktree })?.path ?? requestedPath
  }

  public static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
    isSameOrDescendant(normalize(path), ofNormalizedRoot: normalize(root))
  }

  private static func chooseBetterMatch(
    current: (rootPath: String, matchedLength: Int)?,
    candidate: (rootPath: String, matchedLength: Int)
  ) -> (rootPath: String, matchedLength: Int) {
    guard let current else { return candidate }
    return candidate.matchedLength > current.matchedLength ? candidate : current
  }

  private static func isSameOrDescendant(
    _ normalizedPath: String,
    ofNormalizedRoot normalizedRoot: String
  ) -> Bool {
    guard !normalizedRoot.isEmpty else { return false }
    if normalizedPath == normalizedRoot { return true }
    if normalizedRoot == "/" { return normalizedPath.hasPrefix("/") }
    return normalizedPath.hasPrefix(normalizedRoot + "/")
  }

  private static func normalize(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
