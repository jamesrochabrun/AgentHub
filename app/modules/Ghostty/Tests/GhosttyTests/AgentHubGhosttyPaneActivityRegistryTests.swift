import Foundation
import GhosttySwift
import Testing

@testable import Ghostty

@Suite("AgentHub Ghostty pane activity registry")
struct AgentHubGhosttyPaneActivityRegistryTests {

  @Test("Marking a pane as starting exposes the starting activity")
  func markingPaneStartingExposesStartingActivity() {
    let registry = AgentHubGhosttyPaneActivityRegistry()
    let panelID = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    registry.markStarting(panelID)

    #expect(registry.activity(for: panelID) == .starting)
    #expect(registry.activity(for: panelID)?.message == "Starting terminal...")
  }

  @Test("Marking a pane as closing panel exposes the closing panel activity")
  func markingPaneClosingPanelExposesClosingPanelActivity() {
    let registry = AgentHubGhosttyPaneActivityRegistry()
    let panelID = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    registry.markClosingPanel(panelID)

    #expect(registry.activity(for: panelID) == .closingPanel)
    #expect(registry.activity(for: panelID)?.message == "Closing panel...")
  }

  @Test("Marking a pane as closing terminal exposes the closing terminal activity")
  func markingPaneClosingTerminalExposesClosingTerminalActivity() {
    let registry = AgentHubGhosttyPaneActivityRegistry()
    let panelID = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    registry.markClosingTerminal(panelID)

    #expect(registry.activity(for: panelID) == .closingTerminal)
    #expect(registry.activity(for: panelID)?.message == "Closing terminal...")
  }

  @Test("Clearing a pane removes its activity")
  func clearingPaneRemovesActivity() {
    let registry = AgentHubGhosttyPaneActivityRegistry()
    let panelID = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    registry.markStarting(panelID)

    let didClearActivity = registry.clear(panelID)

    #expect(didClearActivity)
    #expect(registry.activity(for: panelID) == nil)
  }

  @Test("Clearing a pane without activity reports no change")
  func clearingPaneWithoutActivityReportsNoChange() {
    let registry = AgentHubGhosttyPaneActivityRegistry()
    let panelID = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    let didClearActivity = registry.clear(panelID)

    #expect(!didClearActivity)
  }

  @Test("Reset removes all pane activities")
  func resetRemovesAllActivities() {
    let registry = AgentHubGhosttyPaneActivityRegistry()
    let firstPanelID = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let secondPanelID = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    registry.markStarting(firstPanelID)
    registry.markStarting(secondPanelID)

    registry.reset()

    #expect(registry.activity(for: firstPanelID) == nil)
    #expect(registry.activity(for: secondPanelID) == nil)
  }
}
