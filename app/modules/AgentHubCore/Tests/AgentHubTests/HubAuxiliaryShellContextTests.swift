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

  @Test("Pending session without generated worktree requirements is launchable")
  func pendingImmediateWorktreeContext() {
    let pending = PendingHubSession(
      worktree: WorktreeBranch(
        name: "feature-branch",
        path: "/tmp/worktree",
        isWorktree: true
      )
    )

    let context = HubAuxiliaryShellContext.pending(pending: pending, providerKind: .claude)

    #expect(context.terminalKey == "pending-\(pending.id.uuidString)")
    #expect(context.sessionId == nil)
    #expect(context.projectPath == "/tmp/worktree")
    #expect(context.isLaunchable)
    #expect(context.placeholderMessage == nil)
  }

  @Test("Pending Claude named worktree waits until the derived worktree path exists")
  func pendingNamedClaudeWorktreeWaitsForDirectory() throws {
    let repoRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repoRoot) }

    let pending = PendingHubSession(
      worktree: WorktreeBranch(
        name: "main",
        path: repoRoot.path,
        isWorktree: true
      ),
      worktreeName: "feature-shell"
    )

    let context = HubAuxiliaryShellContext.pending(pending: pending, providerKind: .claude)

    #expect(context.terminalKey == "pending-\(pending.id.uuidString)")
    #expect(context.projectPath == nil)
    #expect(!context.isLaunchable)
    #expect(context.placeholderMessage == "Shell will be available once Claude creates the worktree.")
  }

  @Test("Pending Claude named worktree becomes launchable once the derived path exists")
  func pendingNamedClaudeWorktreeLaunchesWhenDirectoryExists() throws {
    let repoRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let derivedWorktreePath = repoRoot
      .appendingPathComponent(".claude")
      .appendingPathComponent("worktrees")
      .appendingPathComponent("feature-shell")

    try FileManager.default.createDirectory(at: derivedWorktreePath, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repoRoot) }

    let pending = PendingHubSession(
      worktree: WorktreeBranch(
        name: "main",
        path: repoRoot.path,
        isWorktree: true
      ),
      worktreeName: "feature-shell"
    )

    let context = HubAuxiliaryShellContext.pending(pending: pending, providerKind: .claude)

    #expect(context.projectPath == derivedWorktreePath.path)
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
    #expect(context.placeholderMessage == "Shell will be available once Claude creates the worktree.")
  }
}
