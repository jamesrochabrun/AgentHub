//
//  GitHubReviewSessionLaunchTargetResolver.swift
//  AgentHub
//

import Foundation

struct GitHubReviewSessionLaunchTarget: Equatable {
  let worktree: WorktreeBranch
  let parentRepositoryPath: String?
}

enum GitHubReviewSessionLaunchTargetResolver {
  static func launchTarget(
    for projectPath: String,
    repositories: [SelectedRepository]
  ) -> GitHubReviewSessionLaunchTarget {
    let normalizedPath = WorktreeModuleResolver.normalizedDirectoryPath(projectPath)

    guard let match = WorktreeModuleResolver.bestMatch(for: normalizedPath, repositories: repositories) else {
      return GitHubReviewSessionLaunchTarget(
        worktree: WorktreeBranch(
          name: URL(fileURLWithPath: normalizedPath).lastPathComponent,
          path: normalizedPath,
          isWorktree: false,
          isExpanded: true
        ),
        parentRepositoryPath: nil
      )
    }

    if match.worktree.isWorktree {
      return GitHubReviewSessionLaunchTarget(
        worktree: WorktreeBranch(
          name: match.worktree.name,
          path: WorktreeModuleResolver.normalizedDirectoryPath(match.worktree.path),
          isWorktree: true,
          sessions: match.worktree.sessions,
          isExpanded: match.worktree.isExpanded
        ),
        parentRepositoryPath: WorktreeModuleResolver.normalizedDirectoryPath(match.repository.path)
      )
    }

    return GitHubReviewSessionLaunchTarget(
      worktree: WorktreeBranch(
        name: match.worktree.name,
        path: WorktreeModuleResolver.normalizedDirectoryPath(match.repository.path),
        isWorktree: false,
        sessions: match.worktree.sessions,
        isExpanded: match.worktree.isExpanded
      ),
      parentRepositoryPath: nil
    )
  }
}
