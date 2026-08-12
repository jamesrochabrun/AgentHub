import Foundation
import Testing

@testable import AgentHubCore

@Suite("Session hover preview")
struct SessionHoverPreviewTests {

  private func repo() -> SelectedRepository {
    SelectedRepository(
      path: "/tmp/RepoA",
      worktrees: [
        WorktreeBranch(name: "main", path: "/tmp/RepoA", isWorktree: false),
        WorktreeBranch(name: "feature/popup", path: "/tmp/RepoA-popup", isWorktree: true)
      ]
    )
  }

  @Test("Worktree session resolves parent repo and registered worktree root")
  func worktreeSessionResolvesParentRepo() {
    let session = CLISession(
      id: "11111111-aaaa-bbbb-cccc-000000000001",
      projectPath: "/tmp/RepoA-popup",
      branchName: "feature/popup",
      isWorktree: true,
      firstMessage: "Add a hover popup"
    )

    let preview = SessionHoverPreview.make(
      session: session,
      customName: nil,
      repositories: [repo()]
    )

    #expect(preview.repositoryName == "RepoA")
    #expect(preview.worktreePath == "/tmp/RepoA-popup")
    #expect(preview.branchName == "feature/popup")
    #expect(preview.firstMessage == "Add a hover popup")
  }

  @Test("Nested launch path maps back to the worktree root")
  func nestedLaunchPathResolvesWorktreeRoot() {
    let session = CLISession(
      id: "11111111-aaaa-bbbb-cccc-000000000002",
      projectPath: "/tmp/RepoA-popup/ios/App",
      isWorktree: true
    )

    let preview = SessionHoverPreview.make(
      session: session,
      customName: nil,
      repositories: [repo()]
    )

    #expect(preview.repositoryName == "RepoA")
    #expect(preview.worktreePath == "/tmp/RepoA-popup")
    #expect(preview.branchName == "feature/popup")
  }

  @Test("Root session has no worktree path")
  func rootSessionHasNoWorktreePath() {
    let session = CLISession(
      id: "11111111-aaaa-bbbb-cccc-000000000003",
      projectPath: "/tmp/RepoA",
      branchName: "main"
    )

    let preview = SessionHoverPreview.make(
      session: session,
      customName: nil,
      repositories: [repo()]
    )

    #expect(preview.repositoryName == "RepoA")
    #expect(preview.worktreePath == nil)
    #expect(preview.branchName == "main")
  }

  @Test("Unmatched repository falls back to path-derived names")
  func unmatchedRepositoryFallsBack() {
    let session = CLISession(
      id: "11111111-aaaa-bbbb-cccc-000000000004",
      projectPath: "/tmp/Elsewhere-wt",
      branchName: "fix/thing",
      isWorktree: true
    )

    let preview = SessionHoverPreview.make(
      session: session,
      customName: nil,
      repositories: [repo()]
    )

    #expect(preview.repositoryName == "Elsewhere-wt")
    #expect(preview.worktreePath == "/tmp/Elsewhere-wt")
    #expect(preview.branchName == "fix/thing")
  }

  @Test("Session name prefers custom name, then slug, then short ID")
  func sessionNamePrecedence() {
    let session = CLISession(
      id: "abcdef12-3456-7890-aaaa-000000000005",
      projectPath: "/tmp/RepoA",
      slug: "cryptic-orbiting-flame"
    )

    let custom = SessionHoverPreview.make(
      session: session,
      customName: "My Session",
      repositories: [repo()]
    )
    #expect(custom.sessionName == "My Session")

    let slugged = SessionHoverPreview.make(
      session: session,
      customName: nil,
      repositories: [repo()]
    )
    #expect(slugged.sessionName == "cryptic-orbiting-flame")

    var noSlug = session
    noSlug.slug = nil
    let short = SessionHoverPreview.make(
      session: noSlug,
      customName: nil,
      repositories: [repo()]
    )
    #expect(short.sessionName == "abcdef12")
  }

  @Test("Blank first message becomes nil")
  func blankFirstMessageBecomesNil() {
    let session = CLISession(
      id: "11111111-aaaa-bbbb-cccc-000000000006",
      projectPath: "/tmp/RepoA",
      firstMessage: "   \n  "
    )

    let preview = SessionHoverPreview.make(
      session: session,
      customName: nil,
      repositories: [repo()]
    )

    #expect(preview.firstMessage == nil)
  }

  @Test("Display worktree path abbreviates the home directory")
  func displayWorktreePathAbbreviatesHome() {
    let preview = SessionHoverPreview(
      sessionName: "name",
      firstMessage: nil,
      repositoryName: "RepoA",
      branchName: "main",
      worktreePath: "/Users/dev/Developer/RepoA-popup"
    )

    #expect(
      preview.displayWorktreePath(homeDirectory: "/Users/dev")
        == "~/Developer/RepoA-popup"
    )
    #expect(
      preview.displayWorktreePath(homeDirectory: "/Users/other")
        == "/Users/dev/Developer/RepoA-popup"
    )
  }
}
