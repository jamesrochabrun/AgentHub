import Testing

@testable import AgentHubCore

@Suite("ModuleLandingSelection")
struct ModuleLandingSelectionTests {
  @Test("Returns selected module when it has no items")
  func returnsSelectedEmptyModule() {
    let repository = SelectedRepository(path: "/tmp/AgentHub")

    let activePath = ModuleLandingSelection.activeModulePath(
      selectedPath: repository.path,
      repositories: [repository],
      itemProjectPaths: []
    )

    #expect(activePath == repository.path)
  }

  @Test("Clears selected module when a worktree item belongs to it")
  func clearsModuleWithWorktreeItem() {
    let repository = SelectedRepository(
      path: "/tmp/AgentHub",
      worktrees: [
        WorktreeBranch(
          name: "feature",
          path: "/tmp/AgentHub-feature",
          isWorktree: true
        )
      ]
    )

    let activePath = ModuleLandingSelection.activeModulePath(
      selectedPath: repository.path,
      repositories: [repository],
      itemProjectPaths: ["/tmp/AgentHub-feature"]
    )

    #expect(activePath == nil)
  }

  @Test("Clears missing or unselected module")
  func clearsMissingOrUnselectedModule() {
    let repository = SelectedRepository(path: "/tmp/AgentHub")

    let noSelection = ModuleLandingSelection.activeModulePath(
      selectedPath: nil,
      repositories: [repository],
      itemProjectPaths: []
    )
    let removedSelection = ModuleLandingSelection.activeModulePath(
      selectedPath: "/tmp/Removed",
      repositories: [repository],
      itemProjectPaths: []
    )

    #expect(noSelection == nil)
    #expect(removedSelection == nil)
  }

  @Test("Does not activate before the module is tracked")
  func doesNotActivateBeforeRepositoryRowExists() {
    let activePath = ModuleLandingSelection.activeModulePath(
      selectedPath: "/tmp/NewModule",
      repositories: [],
      itemProjectPaths: []
    )

    #expect(activePath == nil)
  }
}
