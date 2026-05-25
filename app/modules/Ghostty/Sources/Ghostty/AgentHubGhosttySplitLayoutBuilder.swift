//
//  AgentHubGhosttySplitLayoutBuilder.swift
//  AgentHub
//

import AgentHubCore
import GhosttySwift

enum AgentHubGhosttySplitLayoutBuilder {
  static func snapshotNode(
    from root: TerminalSplitLayout.Node,
    panelIDs: [TerminalPanelID]
  ) -> TerminalWorkspaceSplitNode? {
    let indexByPanelID = Dictionary(
      uniqueKeysWithValues: panelIDs.enumerated().map { index, panelID in
        (panelID, index)
      }
    )
    return snapshotNode(from: root, indexByPanelID: indexByPanelID)
  }

  static func terminalNode(
    from snapshotNode: TerminalWorkspaceSplitNode,
    panelIDByIndex: [Int: TerminalPanelID]
  ) -> TerminalSplitLayout.Node? {
    switch snapshotNode {
    case .panel(let index):
      guard let panelID = panelIDByIndex[index] else { return nil }
      return .panel(panelID)

    case .split(let axis, let children):
      let restoredChildren = children.compactMap {
        terminalNode(from: $0, panelIDByIndex: panelIDByIndex)
      }
      guard !restoredChildren.isEmpty else { return nil }
      return .split(axis: TerminalSplitAxis(axis), children: restoredChildren)
    }
  }

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

  private static func snapshotNode(
    from root: TerminalSplitLayout.Node,
    indexByPanelID: [TerminalPanelID: Int]
  ) -> TerminalWorkspaceSplitNode? {
    switch root {
    case .panel(let panelID):
      guard let index = indexByPanelID[panelID] else { return nil }
      return .panel(index: index)

    case .split(let axis, let children):
      let snapshotChildren = children.compactMap {
        snapshotNode(from: $0, indexByPanelID: indexByPanelID)
      }
      guard !snapshotChildren.isEmpty else { return nil }
      return .split(axis: TerminalWorkspaceSplitAxis(axis), children: snapshotChildren)
    }
  }
}

private extension TerminalWorkspaceSplitAxis {
  init(_ axis: TerminalSplitAxis) {
    switch axis {
    case .horizontal:
      self = .horizontal
    case .vertical:
      self = .vertical
    }
  }
}

private extension TerminalSplitAxis {
  init(_ axis: TerminalWorkspaceSplitAxis) {
    switch axis {
    case .horizontal:
      self = .horizontal
    case .vertical:
      self = .vertical
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
