import Foundation
import Testing

@testable import AgentHubCore

@Suite("HubAuxiliaryShellContext")
struct HubAuxiliaryShellContextTests {

  @Test("Monitored session resolves to launchable shell context")
  func monitoredSessionContext() {
    let session = CLISession(
      id: "session-123",
      projectPath: "/tmp/project",
      branchName: "main"
    )

    let context = HubAuxiliaryShellContext.monitored(session: session, providerKind: .claude)

    #expect(context.providerKind == .claude)
    #expect(context.terminalKey == "session-123")
    #expect(context.sessionId == "session-123")
    #expect(context.projectPath == "/tmp/project")
    #expect(context.isLaunchable)
    #expect(context.placeholderMessage == nil)
  }

  @Test("Pending session with known worktree path is launchable")
  func pendingKnownWorktreeContext() {
    let pending = PendingHubSession(
      worktree: WorktreeBranch(
        name: "feature-shell",
        path: "/tmp/worktree",
        isWorktree: true
      ),
      worktreeName: "feature-shell"
    )

    let context = HubAuxiliaryShellContext.pending(pending: pending, providerKind: .claude)

    #expect(context.terminalKey == "pending-\(pending.id.uuidString)")
    #expect(context.sessionId == nil)
    #expect(context.projectPath == "/tmp/worktree")
    #expect(context.isLaunchable)
    #expect(context.placeholderMessage == nil)
  }

  @Test("Pending Claude auto-worktree waits for resolved path")
  func pendingAutoWorktreeContext() {
    let pending = PendingHubSession(
      worktree: WorktreeBranch(
        name: "main",
        path: "/tmp/repo",
        isWorktree: true
      ),
      worktreeName: ""
    )

    let context = HubAuxiliaryShellContext.pending(pending: pending, providerKind: .claude)

    #expect(context.terminalKey == "pending-\(pending.id.uuidString)")
    #expect(context.projectPath == nil)
    #expect(!context.isLaunchable)
    #expect(context.placeholderMessage == "Shell will be available once the worktree path is created.")
  }
}
