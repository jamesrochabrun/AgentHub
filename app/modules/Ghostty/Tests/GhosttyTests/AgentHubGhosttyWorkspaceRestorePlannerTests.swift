import AgentHubCore
import Foundation
import Testing

@testable import Ghostty

@Suite("AgentHub Ghostty workspace restore planner")
struct AgentHubGhosttyWorkspaceRestorePlannerTests {

  // MARK: - Primary panel, neutral workspace

  @Test("Placeholder shell stands in for a leading plain shell tab")
  func primaryReusesPlaceholderForLeadingPlainShell() {
    let shell = Self.shellTab()
    let agent = Self.linkedAgentTab(provider: .claude, sessionId: "claude-1")

    let plan = AgentHubGhosttyWorkspaceRestorePlanner.primaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .primary, tabs: [shell, agent]),
      hasProtectedAgentTab: false
    )

    #expect(plan.reusesExistingTab)
    #expect(plan.tabsToOpen == [agent])
  }

  @Test("A leading linked agent tab is restored, never replaced by the placeholder shell")
  func primaryRestoresLeadingLinkedAgentTab() {
    let agent = Self.linkedAgentTab(provider: .claude, sessionId: "claude-1")

    let plan = AgentHubGhosttyWorkspaceRestorePlanner.primaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .primary, tabs: [agent]),
      hasProtectedAgentTab: false
    )

    #expect(!plan.reusesExistingTab)
    #expect(plan.tabsToOpen == [agent])
  }

  @Test("Snapshot order is preserved when an agent tab precedes a shell tab")
  func primaryPreservesOrderWhenAgentTabLeads() {
    let agent = Self.linkedAgentTab(provider: .codex, sessionId: "codex-1")
    let shell = Self.shellTab()

    let plan = AgentHubGhosttyWorkspaceRestorePlanner.primaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .primary, tabs: [agent, shell]),
      hasProtectedAgentTab: false
    )

    #expect(!plan.reusesExistingTab)
    #expect(plan.tabsToOpen == [agent, shell])
  }

  @Test("An unlinked agent tab degrades to a restorable tab instead of vanishing")
  func primaryKeepsUnlinkedAgentTab() {
    let shell = Self.shellTab()
    let unlinkedAgent = Self.unlinkedAgentTab()

    let plan = AgentHubGhosttyWorkspaceRestorePlanner.primaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .primary, tabs: [shell, unlinkedAgent]),
      hasProtectedAgentTab: false
    )

    #expect(plan.reusesExistingTab)
    #expect(plan.tabsToOpen == [unlinkedAgent])
  }

  @Test("An empty primary snapshot keeps the placeholder shell")
  func primaryWithNoTabsKeepsPlaceholder() {
    let plan = AgentHubGhosttyWorkspaceRestorePlanner.primaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .primary, tabs: []),
      hasProtectedAgentTab: false
    )

    #expect(!plan.reusesExistingTab)
    #expect(plan.tabsToOpen.isEmpty)
  }

  // MARK: - Primary panel, protected session surface

  @Test("Protected surfaces keep the retained agent tab and skip its snapshot twin")
  func protectedPrimarySkipsUnlinkedAgentTabs() {
    let protectedTwin = Self.unlinkedAgentTab()
    let shell = Self.shellTab()
    let linkedChild = Self.linkedAgentTab(provider: .codex, sessionId: "codex-child")

    let plan = AgentHubGhosttyWorkspaceRestorePlanner.primaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .primary, tabs: [protectedTwin, shell, linkedChild]),
      hasProtectedAgentTab: true
    )

    #expect(plan.reusesExistingTab)
    #expect(plan.tabsToOpen == [shell, linkedChild])
  }

  // MARK: - Auxiliary panels

  @Test("Auxiliary panels anchor on their first tab and keep the rest in order")
  func auxiliaryAnchorsFirstTab() {
    let codex = Self.linkedAgentTab(provider: .codex, sessionId: "codex-1")
    let claude = Self.linkedAgentTab(provider: .claude, sessionId: "claude-1")

    let plan = AgentHubGhosttyWorkspaceRestorePlanner.auxiliaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .auxiliary, tabs: [codex, claude])
    )

    #expect(plan?.anchorTab == codex)
    #expect(plan?.additionalTabs == [claude])
  }

  @Test("An auxiliary panel holding only an unlinked agent tab is preserved")
  func auxiliaryKeepsUnlinkedAgentPanel() {
    let unlinkedAgent = Self.unlinkedAgentTab()

    let plan = AgentHubGhosttyWorkspaceRestorePlanner.auxiliaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .auxiliary, tabs: [unlinkedAgent])
    )

    #expect(plan?.anchorTab == unlinkedAgent)
    #expect(plan?.additionalTabs.isEmpty == true)
  }

  @Test("An auxiliary panel with no tabs is dropped")
  func auxiliaryWithNoTabsIsDropped() {
    let plan = AgentHubGhosttyWorkspaceRestorePlanner.auxiliaryPlan(
      for: TerminalWorkspacePanelSnapshot(role: .auxiliary, tabs: [])
    )

    #expect(plan == nil)
  }

  // MARK: - Helpers

  private static func shellTab(workingDirectory: String = "/tmp/project") -> TerminalWorkspaceTabSnapshot {
    TerminalWorkspaceTabSnapshot(
      role: .shell,
      name: "Shell",
      title: "Shell",
      workingDirectory: workingDirectory
    )
  }

  private static func unlinkedAgentTab() -> TerminalWorkspaceTabSnapshot {
    TerminalWorkspaceTabSnapshot(
      role: .agent,
      name: "Claude",
      title: "Claude",
      workingDirectory: "/tmp/project"
    )
  }

  private static func linkedAgentTab(
    provider: SessionProviderKind,
    sessionId: String
  ) -> TerminalWorkspaceTabSnapshot {
    TerminalWorkspaceTabSnapshot(
      role: .agent,
      name: provider.rawValue,
      title: provider.rawValue,
      workingDirectory: "/tmp/project",
      linkedSession: TerminalWorkspaceLinkedSessionSnapshot(
        provider: provider,
        sessionId: sessionId,
        relationshipKind: .accessoryChild
      )
    )
  }
}
