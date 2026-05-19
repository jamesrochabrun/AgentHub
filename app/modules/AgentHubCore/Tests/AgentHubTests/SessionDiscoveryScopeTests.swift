import Testing

@testable import AgentHubCore

@Suite("Session discovery scope")
struct SessionDiscoveryScopeTests {
  @Test("Owned worktree sessions must be focused")
  func ownedWorktreeSessionsMustBeFocused() {
    let scope = SessionDiscoveryScope(
      repositoryPaths: ["/tmp/project"],
      ownedWorktreePaths: ["/tmp/project-feature"],
      ignoredWorktreePaths: [],
      focusedSessionIds: ["focused-session"]
    )

    #expect(scope.includes(projectPath: "/tmp/project", sessionId: "external-main"))
    #expect(scope.includes(projectPath: "/tmp/project-feature", sessionId: "focused-session"))
    #expect(!scope.includes(projectPath: "/tmp/project-feature", sessionId: "external-worktree"))
  }

  @Test("Ignored worktrees are not attributed to parent repository")
  func ignoredWorktreesAreNotAttributedToParentRepository() {
    let scope = SessionDiscoveryScope(
      repositoryPaths: ["/tmp/project"],
      ownedWorktreePaths: [],
      ignoredWorktreePaths: ["/tmp/project/.claude/worktrees/external"],
      focusedSessionIds: []
    )

    #expect(scope.includes(projectPath: "/tmp/project/src", sessionId: "main-session"))
    #expect(!scope.includes(projectPath: "/tmp/project/.claude/worktrees/external", sessionId: "external"))
    #expect(!scope.includes(projectPath: "/tmp/project/.claude/worktrees/external/app", sessionId: "external-subdir"))
  }
}
