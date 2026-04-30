//
//  RepositoryWorktreeResolver.swift
//  AgentHub
//

import Foundation

struct RepositoryWorktreeSnapshot: Sendable {
  let rootPath: String
  let worktrees: [WorktreeBranch]
}

enum RepositoryWorktreeResolver {
  static func detectRepository(at path: String) async -> RepositoryWorktreeSnapshot {
    let worktrees = await detectWorktrees(at: path)
    let rootPath = ProjectHierarchyResolver.rootRepositoryPath(
      for: path,
      worktrees: worktrees
    )

    return RepositoryWorktreeSnapshot(
      rootPath: rootPath,
      worktrees: worktrees
    )
  }

  static func detectWorktrees(at path: String) async -> [WorktreeBranch] {
    let worktrees = await GitWorktreeDetector.listWorktrees(at: path)
    if !worktrees.isEmpty {
      return worktrees.map(makeWorktreeBranch)
    }

    guard let info = await GitWorktreeDetector.detectWorktreeInfo(for: path) else {
      return [
        WorktreeBranch(
          name: "main",
          path: path,
          isWorktree: false,
          sessions: []
        )
      ]
    }

    if info.isWorktree, let mainRepoPath = info.mainRepoPath {
      let mainWorktrees = await GitWorktreeDetector.listWorktrees(at: mainRepoPath)
      if !mainWorktrees.isEmpty {
        return mainWorktrees.map(makeWorktreeBranch)
      }
    }

    return [
      WorktreeBranch(
        name: info.branch ?? "main",
        path: path,
        isWorktree: info.isWorktree,
        sessions: []
      )
    ]
  }

  private static func makeWorktreeBranch(_ info: GitWorktreeInfo) -> WorktreeBranch {
    WorktreeBranch(
      name: info.branch ?? URL(fileURLWithPath: info.path).lastPathComponent,
      path: info.path,
      isWorktree: info.isWorktree,
      sessions: []
    )
  }
}
