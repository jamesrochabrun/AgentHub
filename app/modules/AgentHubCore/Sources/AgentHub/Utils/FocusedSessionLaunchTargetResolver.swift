//
//  FocusedSessionLaunchTargetResolver.swift
//  AgentHub
//

import Foundation

enum FocusedSessionLaunchTargetResolver {
  struct SessionItem: Equatable {
    let id: String
    let projectPath: String
  }

  static func launchPath(
    primarySessionId: String?,
    selectedModuleLandingPath: String?,
    items: [SessionItem],
    repositories: [SelectedRepository]
  ) -> String? {
    guard selectedModuleLandingPath == nil,
          let primarySessionId,
          let item = items.first(where: { $0.id == primarySessionId }),
          let match = WorktreeModuleResolver.bestMatch(for: item.projectPath, repositories: repositories) else {
      return nil
    }

    if match.worktree.isWorktree {
      return WorktreeModuleResolver.normalizedDirectoryPath(match.worktree.path)
    }
    return WorktreeModuleResolver.normalizedDirectoryPath(match.repository.path)
  }
}
