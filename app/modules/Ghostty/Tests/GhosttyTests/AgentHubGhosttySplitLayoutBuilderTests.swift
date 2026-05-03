import Foundation
import GhosttySwift
import Testing

@testable import Ghostty

@Suite("AgentHub Ghostty split layout builder")
struct AgentHubGhosttySplitLayoutBuilderTests {

  @Test("Split right adds the new panel beside the active panel")
  func splitRightAddsSiblingBesideActivePanel() {
    let primary = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let shell = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    let result = AgentHubGhosttySplitLayoutBuilder.addingPanel(
      shell,
      to: .panel(primary),
      beside: primary,
      axis: .horizontal
    )

    #expect(result == .split(axis: .horizontal, children: [.panel(primary), .panel(shell)]))
  }

  @Test("Split below nests the new panel under the active panel")
  func splitBelowNestsPanelUnderActivePanel() {
    let primary = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let shell1 = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let shell2 = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    let root = TerminalSplitLayout.Node.split(
      axis: .horizontal,
      children: [.panel(primary), .panel(shell1)]
    )

    let result = AgentHubGhosttySplitLayoutBuilder.addingPanel(
      shell2,
      to: root,
      beside: shell1,
      axis: .vertical
    )

    #expect(
      result == .split(
        axis: .horizontal,
        children: [
          .panel(primary),
          .split(axis: .vertical, children: [.panel(shell1), .panel(shell2)])
        ]
      )
    )
  }

  @Test("Removing a panel collapses single-child split groups")
  func removingPanelCollapsesSingleChildSplitGroups() {
    let primary = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let shell1 = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let shell2 = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let root = TerminalSplitLayout.Node.split(
      axis: .horizontal,
      children: [
        .panel(primary),
        .split(axis: .vertical, children: [.panel(shell1), .panel(shell2)])
      ]
    )

    let result = AgentHubGhosttySplitLayoutBuilder.removingPanel(shell1, from: root)

    #expect(result == .split(axis: .horizontal, children: [.panel(primary), .panel(shell2)]))
  }

  @Test("Replacing a placeholder panel preserves the split structure")
  func replacingPlaceholderPanelPreservesSplitStructure() {
    let primary = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let placeholder = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let shell = TerminalPanelID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let root = TerminalSplitLayout.Node.split(
      axis: .vertical,
      children: [.panel(primary), .panel(placeholder)]
    )

    let result = AgentHubGhosttySplitLayoutBuilder.replacingPanel(
      placeholder,
      with: shell,
      in: root
    )

    #expect(result == .split(axis: .vertical, children: [.panel(primary), .panel(shell)]))
  }
}
