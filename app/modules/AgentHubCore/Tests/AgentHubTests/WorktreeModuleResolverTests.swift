import Foundation
import Testing

@testable import AgentHubCore

@Suite("WorktreeModuleResolver")
struct WorktreeModuleResolverTests {
  @Test("Parent mode groups worktree sessions under the parent repository")
  func parentModeUsesParentRepository() {
    let repositories = [
      repositoryWithWorktree(
        repoPath: "/tmp/ModuleA",
        worktreePath: "/tmp/ModuleA-feature"
      )
    ]

    #expect(WorktreeModuleResolver.modulePath(
      for: "/tmp/ModuleA-feature",
      repositories: repositories,
      mode: .parent
    ) == "/tmp/ModuleA")

    #expect(WorktreeModuleResolver.modulePath(
      for: "/tmp/ModuleA-feature/app/Sources",
      repositories: repositories,
      mode: .parent
    ) == "/tmp/ModuleA")
  }

  @Test("Separate mode groups worktree sessions under the worktree path")
  func separateModeUsesWorktreePath() {
    let repositories = [
      repositoryWithWorktree(
        repoPath: "/tmp/ModuleA",
        worktreePath: "/tmp/ModuleA-feature"
      )
    ]

    #expect(WorktreeModuleResolver.modulePath(
      for: "/tmp/ModuleA-feature",
      repositories: repositories,
      mode: .separateModules
    ) == "/tmp/ModuleA-feature")

    #expect(WorktreeModuleResolver.modulePath(
      for: "/tmp/ModuleA-feature/app/Sources",
      repositories: repositories,
      mode: .separateModules
    ) == "/tmp/ModuleA-feature")
  }

  @Test("Module path list follows the selected worktree display mode")
  func modulePathsFollowDisplayMode() {
    let repositories = [
      repositoryWithWorktree(
        repoPath: "/tmp/ModuleA",
        worktreePath: "/tmp/ModuleA-feature"
      )
    ]

    #expect(WorktreeModuleResolver.modulePaths(for: repositories, mode: .parent) == [
      "/tmp/ModuleA"
    ])
    #expect(WorktreeModuleResolver.modulePaths(for: repositories, mode: .separateModules) == [
      "/tmp/ModuleA",
      "/tmp/ModuleA-feature"
    ])
  }

  @Test("Merged repositories keep worktrees from both providers")
  func mergedRepositoriesKeepProviderWorktrees() throws {
    let claude = SelectedRepository(
      path: "/tmp/ModuleA",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/ModuleA", isWorktree: false)
      ]
    )
    let codex = SelectedRepository(
      path: "/tmp/ModuleA",
      worktrees: [
        WorktreeBranch(name: "feature", path: "/tmp/ModuleA-feature", isWorktree: true)
      ]
    )

    let merged = WorktreeModuleResolver.mergedRepositories([claude, codex])
    let repository = try #require(merged.first)

    #expect(merged.count == 1)
    #expect(repository.worktrees.map(\.path).sorted() == [
      "/tmp/ModuleA",
      "/tmp/ModuleA-feature"
    ])
  }
}

private func repositoryWithWorktree(repoPath: String, worktreePath: String) -> SelectedRepository {
  SelectedRepository(
    path: repoPath,
    worktrees: [
      WorktreeBranch(name: "main", path: repoPath, isWorktree: false),
      WorktreeBranch(name: "feature", path: worktreePath, isWorktree: true)
    ]
  )
}
