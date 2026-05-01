import Testing

@testable import AgentHubCore

@Suite("ProjectHierarchyResolver")
struct ProjectHierarchyResolverTests {
  @Test("Maps worktree sessions to the root repository")
  func mapsWorktreeSessionToRootRepository() {
    let repository = makeRepository()

    let rootPath = ProjectHierarchyResolver.rootProjectPath(
      for: "/tmp/AgentHub/project-feature",
      repositories: [repository]
    )

    #expect(rootPath == "/tmp/AgentHub/project")
  }

  @Test("Maps worktree subdirectory sessions to the root repository")
  func mapsWorktreeSubdirectorySessionToRootRepository() {
    let repository = makeRepository()

    let rootPath = ProjectHierarchyResolver.rootProjectPath(
      for: "/tmp/AgentHub/project-feature/app/Sources",
      repositories: [repository]
    )

    #expect(rootPath == "/tmp/AgentHub/project")
  }

  @Test("Uses path boundaries instead of sibling prefixes")
  func usesPathBoundariesInsteadOfSiblingPrefixes() {
    let repository = makeRepository()

    let rootPath = ProjectHierarchyResolver.rootProjectPath(
      for: "/tmp/AgentHub/project-feature-copy",
      repositories: [repository]
    )

    #expect(rootPath == "/tmp/AgentHub/project-feature-copy")
  }

  @Test("Returns the main worktree as the root repository path")
  func returnsMainWorktreeAsRootRepositoryPath() {
    let rootPath = ProjectHierarchyResolver.rootRepositoryPath(
      for: "/tmp/AgentHub/project-feature",
      worktrees: makeRepository().worktrees
    )

    #expect(rootPath == "/tmp/AgentHub/project")
  }

  private func makeRepository() -> SelectedRepository {
    SelectedRepository(
      path: "/tmp/AgentHub/project",
      worktrees: [
        WorktreeBranch(
          name: "main",
          path: "/tmp/AgentHub/project",
          isWorktree: false
        ),
        WorktreeBranch(
          name: "feature",
          path: "/tmp/AgentHub/project-feature",
          isWorktree: true
        )
      ]
    )
  }
}
