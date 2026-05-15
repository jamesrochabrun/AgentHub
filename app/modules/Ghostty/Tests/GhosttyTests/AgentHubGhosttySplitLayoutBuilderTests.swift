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

  // MARK: - panelID(adjacentTo:direction:in:)

  @Test("Adjacent navigation in a single-panel layout returns nil")
  func adjacentNavigationSinglePanelReturnsNil() {
    let primary = makePanelID(1)
    let root = TerminalSplitLayout.Node.panel(primary)

    for direction in [TerminalPanelNavigationDirection.left, .right, .up, .down] {
      #expect(
        AgentHubGhosttySplitLayoutBuilder.panelID(
          adjacentTo: primary,
          direction: direction,
          in: root
        ) == nil
      )
    }
  }

  @Test("Right and left move between siblings of a horizontal split")
  func adjacentNavigationTwoPaneHorizontal() {
    let left = makePanelID(1)
    let right = makePanelID(2)
    let root = TerminalSplitLayout.Node.split(
      axis: .horizontal,
      children: [.panel(left), .panel(right)]
    )

    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: left, direction: .right, in: root
      ) == right
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: right, direction: .left, in: root
      ) == left
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: left, direction: .left, in: root
      ) == nil
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: right, direction: .right, in: root
      ) == nil
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: left, direction: .up, in: root
      ) == nil
    )
  }

  @Test("Down and up move between siblings of a vertical split")
  func adjacentNavigationTwoPaneVertical() {
    let top = makePanelID(1)
    let bottom = makePanelID(2)
    let root = TerminalSplitLayout.Node.split(
      axis: .vertical,
      children: [.panel(top), .panel(bottom)]
    )

    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: top, direction: .down, in: root
      ) == bottom
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: bottom, direction: .up, in: root
      ) == top
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: top, direction: .left, in: root
      ) == nil
    )
  }

  @Test("Right from the primary in an L-shape enters the top of the right column")
  func adjacentNavigationLShapeRight() {
    let primary = makePanelID(1)
    let topRight = makePanelID(2)
    let bottomRight = makePanelID(3)
    let root = TerminalSplitLayout.Node.split(
      axis: .horizontal,
      children: [
        .panel(primary),
        .split(axis: .vertical, children: [.panel(topRight), .panel(bottomRight)])
      ]
    )

    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: primary, direction: .right, in: root
      ) == topRight
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: topRight, direction: .left, in: root
      ) == primary
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: bottomRight, direction: .left, in: root
      ) == primary
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: topRight, direction: .down, in: root
      ) == bottomRight
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: bottomRight, direction: .up, in: root
      ) == topRight
    )
  }

  @Test("Navigation in a 2x2 grid steps to the matching row or column")
  func adjacentNavigationTwoByTwoGrid() {
    let topLeft = makePanelID(1)
    let topRight = makePanelID(2)
    let bottomLeft = makePanelID(3)
    let bottomRight = makePanelID(4)
    let root = TerminalSplitLayout.Node.split(
      axis: .vertical,
      children: [
        .split(axis: .horizontal, children: [.panel(topLeft), .panel(topRight)]),
        .split(axis: .horizontal, children: [.panel(bottomLeft), .panel(bottomRight)])
      ]
    )

    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: topLeft, direction: .right, in: root
      ) == topRight
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: topLeft, direction: .down, in: root
      ) == bottomLeft
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: topRight, direction: .left, in: root
      ) == topLeft
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: bottomRight, direction: .up, in: root
      ) == topLeft
    )
    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: bottomRight, direction: .left, in: root
      ) == bottomLeft
    )
  }

  @Test("Adjacent navigation returns nil when panel is missing")
  func adjacentNavigationMissingPanelReturnsNil() {
    let primary = makePanelID(1)
    let other = makePanelID(2)
    let missing = makePanelID(99)
    let root = TerminalSplitLayout.Node.split(
      axis: .horizontal,
      children: [.panel(primary), .panel(other)]
    )

    #expect(
      AgentHubGhosttySplitLayoutBuilder.panelID(
        adjacentTo: missing, direction: .left, in: root
      ) == nil
    )
  }

  private func makePanelID(_ value: Int) -> TerminalPanelID {
    let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    return TerminalPanelID(uuid)
  }
}
