import Testing
@testable import AgentHubCore

@Suite("SidePanelContent pending-session rebinding")
struct SidePanelContentTests {
  @Test("Pending simulator panel rebinds to the real session")
  func pendingSimulatorRebindsToRealSession() {
    let pending = CLISession(id: "pending-session", projectPath: "/tmp/project")
    let real = CLISession(id: "real-session", projectPath: "/tmp/project")
    let content = SidePanelContent.simulator(
      sessionId: pending.id,
      session: pending,
      projectPath: pending.projectPath
    )

    #expect(content.replacingPendingSession(with: real) == .simulator(
      sessionId: real.id,
      session: real,
      projectPath: real.projectPath
    ))
  }

  @Test("Pending web preview panel still rebinds to the real session")
  func pendingWebPreviewRebindsToRealSession() {
    let pending = CLISession(id: "pending-session", projectPath: "/tmp/project")
    let real = CLISession(id: "real-session", projectPath: "/tmp/project")
    let content = SidePanelContent.webPreview(
      sessionId: pending.id,
      session: pending,
      projectPath: pending.projectPath,
      mode: .app
    )

    #expect(content.replacingPendingSession(with: real) == .webPreview(
      sessionId: real.id,
      session: real,
      projectPath: real.projectPath,
      mode: .app
    ))
  }

  @Test("Pending panels do not rebind across project paths")
  func pendingPanelDoesNotRebindAcrossProjectPaths() {
    let pending = CLISession(id: "pending-session", projectPath: "/tmp/project-a")
    let real = CLISession(id: "real-session", projectPath: "/tmp/project-b")
    let content = SidePanelContent.simulator(
      sessionId: pending.id,
      session: pending,
      projectPath: pending.projectPath
    )

    #expect(content.replacingPendingSession(with: real) == nil)
  }

  @Test("Non-pending panels do not rebind")
  func nonPendingPanelDoesNotRebind() {
    let existing = CLISession(id: "existing-session", projectPath: "/tmp/project")
    let real = CLISession(id: "real-session", projectPath: "/tmp/project")
    let content = SidePanelContent.simulator(
      sessionId: existing.id,
      session: existing,
      projectPath: existing.projectPath
    )

    #expect(content.replacingPendingSession(with: real) == nil)
  }
}
