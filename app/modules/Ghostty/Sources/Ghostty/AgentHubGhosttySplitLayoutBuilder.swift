//
//  AgentHubGhosttySplitLayoutBuilder.swift
//  AgentHub
//

import GhosttySwift

enum AgentHubGhosttySplitLayoutBuilder {
  static func addingPanel(
    _ newPanelID: TerminalPanelID,
    to root: TerminalSplitLayout.Node,
    beside anchorPanelID: TerminalPanelID,
    axis: TerminalSplitAxis
  ) -> TerminalSplitLayout.Node {
    switch root {
    case .panel(let panelID):
      guard panelID == anchorPanelID else { return root }
      return .split(axis: axis, children: [.panel(panelID), .panel(newPanelID)])

    case .split(let splitAxis, let children):
      let updatedChildren = children.map { child in
        guard child.containsPanel(anchorPanelID) else { return child }
        return addingPanel(newPanelID, to: child, beside: anchorPanelID, axis: axis)
      }
      return .split(axis: splitAxis, children: updatedChildren)
    }
  }

  static func removingPanel(
    _ panelID: TerminalPanelID,
    from root: TerminalSplitLayout.Node
  ) -> TerminalSplitLayout.Node? {
    switch root {
    case .panel(let currentPanelID):
      return currentPanelID == panelID ? nil : root

    case .split(let axis, let children):
      let remainingChildren = children.compactMap { removingPanel(panelID, from: $0) }
      switch remainingChildren.count {
      case 0:
        return nil
      case 1:
        return remainingChildren[0]
      default:
        return .split(axis: axis, children: remainingChildren)
      }
    }
  }

  static func replacingPanel(
    _ currentPanelID: TerminalPanelID,
    with replacementPanelID: TerminalPanelID,
    in root: TerminalSplitLayout.Node
  ) -> TerminalSplitLayout.Node {
    switch root {
    case .panel(let panelID):
      return .panel(panelID == currentPanelID ? replacementPanelID : panelID)

    case .split(let axis, let children):
      return .split(
        axis: axis,
        children: children.map {
          replacingPanel(currentPanelID, with: replacementPanelID, in: $0)
        }
      )
    }
  }
}

private extension TerminalSplitLayout.Node {
  func containsPanel(_ panelID: TerminalPanelID) -> Bool {
    switch self {
    case .panel(let currentPanelID):
      return currentPanelID == panelID
    case .split(_, let children):
      return children.contains { $0.containsPanel(panelID) }
    }
  }
}
