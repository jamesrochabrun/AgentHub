import Foundation
import Testing

@testable import AgentHubCLIKit

@Suite("WorktreeNaming.availableBranchName")
struct WorktreeNamingTests {

  @Test("Returns the requested name unchanged when nothing collides")
  func returnsRequestedWhenFree() {
    let name = WorktreeNaming.availableBranchName(
      for: "agent-add-logging",
      takenBranches: ["main", "develop"],
      takenDirectoryNames: ["some-other-worktree"]
    )
    #expect(name == "agent-add-logging")
  }

  @Test("Appends a numeric suffix when the branch name is taken")
  func suffixesOnBranchCollision() {
    let name = WorktreeNaming.availableBranchName(
      for: "agent-update-chat",
      takenBranches: ["agent-update-chat"],
      takenDirectoryNames: []
    )
    #expect(name == "agent-update-chat-2")
  }

  @Test("Skips suffixes that are also taken")
  func skipsTakenSuffixes() {
    let name = WorktreeNaming.availableBranchName(
      for: "agent-task",
      takenBranches: ["agent-task", "agent-task-2", "agent-task-3"],
      takenDirectoryNames: []
    )
    #expect(name == "agent-task-4")
  }

  @Test("Treats a colliding worktree directory as taken")
  func detectsDirectoryCollision() {
    // The requested branch isn't a branch yet, but its derived worktree
    // directory already exists on disk, so it must be disambiguated.
    let directory = WorktreeNaming.worktreeDirectoryName(for: "feature/x")
    let name = WorktreeNaming.availableBranchName(
      for: "feature/x",
      takenBranches: [],
      takenDirectoryNames: [directory]
    )
    #expect(name == "feature/x-2")
  }

  @Test("Considers both branch and directory namespaces when suffixing")
  func considersBothNamespaces() {
    // `agent-foo` collides as a branch; `agent-foo-2` collides as a directory.
    let dirFor2 = WorktreeNaming.worktreeDirectoryName(for: "agent-foo-2")
    let name = WorktreeNaming.availableBranchName(
      for: "agent-foo",
      takenBranches: ["agent-foo"],
      takenDirectoryNames: [dirFor2]
    )
    #expect(name == "agent-foo-3")
  }
}
