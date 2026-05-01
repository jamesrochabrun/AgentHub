import Testing

@testable import AgentHubCore

@Suite("ProjectLandingResolver")
struct ProjectLandingResolverTests {
  @Test("Uses the tracked root repository for an added root path")
  func usesTrackedRootRepositoryForRootPath() {
    let repository = makeRepository()

    let landingPath = ProjectLandingResolver.landingPath(
      for: "/tmp/AgentHub/project",
      repositories: [repository]
    )

    #expect(landingPath == "/tmp/AgentHub/project")
  }

  @Test("Maps an added worktree path to its root repository")
  func mapsAddedWorktreePathToRootRepository() {
    let repository = makeRepository()

    let landingPath = ProjectLandingResolver.landingPath(
      for: "/tmp/AgentHub/project-feature",
      repositories: [repository]
    )

    #expect(landingPath == "/tmp/AgentHub/project")
  }

  @Test("Keeps the added path while the repository is not tracked yet")
  func keepsAddedPathWhenRepositoryIsNotTrackedYet() {
    let landingPath = ProjectLandingResolver.landingPath(
      for: "/tmp/AgentHub/new-project",
      repositories: []
    )

    #expect(landingPath == "/tmp/AgentHub/new-project")
  }

  @Test("Returns the resolved repository for worktree paths")
  func returnsResolvedRepositoryForWorktreePaths() {
    let repository = makeRepository()

    let resolvedRepository = ProjectLandingResolver.resolvedRepository(
      for: "/tmp/AgentHub/project-feature/app",
      repositories: [repository]
    )

    #expect(resolvedRepository?.path == "/tmp/AgentHub/project")
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
