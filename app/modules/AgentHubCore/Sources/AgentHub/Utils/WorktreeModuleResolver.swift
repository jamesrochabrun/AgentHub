//
//  WorktreeModuleResolver.swift
//  AgentHub
//

import Foundation

public enum WorktreeModuleResolver {
  public struct Match: Sendable, Equatable {
    public let repository: SelectedRepository
    public let worktree: WorktreeBranch
  }

  public static func modulePath(
    for itemPath: String,
    repositories: [SelectedRepository],
    mode: WorktreeDisplayMode
  ) -> String {
    guard let match = bestMatch(for: itemPath, repositories: repositories) else {
      return normalizedDirectoryPath(itemPath)
    }

    switch mode {
    case .parent:
      return match.repository.path
    case .separateModules:
      return match.worktree.isWorktree ? match.worktree.path : match.repository.path
    }
  }

  public static func bestMatch(
    for itemPath: String,
    repositories: [SelectedRepository]
  ) -> Match? {
    let normalizedItemPath = normalizedDirectoryPath(itemPath)
    var best: Match?

    for repository in repositories {
      let normalizedRepositoryPath = normalizedDirectoryPath(repository.path)
      if path(normalizedItemPath, isContainedIn: normalizedRepositoryPath) {
        let mainWorktree = repository.worktrees.first(where: { !$0.isWorktree && normalizedDirectoryPath($0.path) == normalizedRepositoryPath })
          ?? WorktreeBranch(name: repository.name, path: repository.path, isWorktree: false)
        best = preferLongerPath(
          current: best,
          candidate: Match(repository: repository, worktree: mainWorktree)
        )
      }

      for worktree in repository.worktrees {
        let worktreePath = normalizedDirectoryPath(worktree.path)
        guard path(normalizedItemPath, isContainedIn: worktreePath) else { continue }
        best = preferLongerPath(
          current: best,
          candidate: Match(repository: repository, worktree: worktree)
        )
      }
    }

    return best
  }

  public static func modulePaths(
    for repositories: [SelectedRepository],
    mode: WorktreeDisplayMode
  ) -> [String] {
    var seen: Set<String> = []
    var paths: [String] = []

    for repository in repositories {
      append(repository.path, to: &paths, seen: &seen)

      guard mode == .separateModules else { continue }
      for worktree in repository.worktrees where worktree.isWorktree {
        append(worktree.path, to: &paths, seen: &seen)
      }
    }

    return paths
  }

  public static func mergedRepositories(_ repositories: [SelectedRepository]) -> [SelectedRepository] {
    var result: [SelectedRepository] = []
    var indicesByPath: [String: Int] = [:]

    for repository in repositories {
      let path = normalizedDirectoryPath(repository.path)
      if let index = indicesByPath[path] {
        result[index] = merge(result[index], with: repository)
      } else {
        indicesByPath[path] = result.count
        result.append(repository)
      }
    }

    return result
  }

  public static func normalizedDirectoryPath(_ path: String) -> String {
    var normalized = path
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }

  private static func path(_ path: String, isContainedIn root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }

  private static func preferLongerPath(current: Match?, candidate: Match) -> Match {
    guard let current else { return candidate }
    return candidate.worktree.path.count > current.worktree.path.count ? candidate : current
  }

  private static func append(_ path: String, to paths: inout [String], seen: inout Set<String>) {
    let normalized = normalizedDirectoryPath(path)
    guard seen.insert(normalized).inserted else { return }
    paths.append(normalized)
  }

  private static func merge(_ existing: SelectedRepository, with incoming: SelectedRepository) -> SelectedRepository {
    var merged = existing
    var worktreePaths = Set(existing.worktrees.map { normalizedDirectoryPath($0.path) })

    for worktree in incoming.worktrees where worktreePaths.insert(normalizedDirectoryPath(worktree.path)).inserted {
      merged.worktrees.append(worktree)
    }

    return merged
  }
}
