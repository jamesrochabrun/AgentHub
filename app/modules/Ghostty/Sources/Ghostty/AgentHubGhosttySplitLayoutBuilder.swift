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

  /// Returns the panel adjacent to `activePanelID` in the given visual direction,
  /// using the split tree as the layout source of truth. Walks up the tree to
  /// find the nearest ancestor split whose axis matches the direction and where
  /// the active subtree has a sibling on the requested side, then descends into
  /// that sibling to the closest leaf panel.
  static func panelID(
    adjacentTo activePanelID: TerminalPanelID,
    direction: TerminalPanelNavigationDirection,
    in root: TerminalSplitLayout.Node
  ) -> TerminalPanelID? {
    guard let path = pathToPanel(activePanelID, in: root) else { return nil }
    let neededAxis = axis(for: direction)
    let forward = isForward(direction)

    for index in stride(from: path.count - 1, through: 1, by: -1) {
      let parent = path[index - 1].node
      let childIndex = path[index].childIndex
      guard case .split(let axis, let children) = parent, axis == neededAxis else { continue }
      let nextIndex = forward ? childIndex + 1 : childIndex - 1
      guard nextIndex >= 0, nextIndex < children.count else { continue }
      return descend(into: children[nextIndex], from: direction)
    }

    return nil
  }

  private static func pathToPanel(
    _ panelID: TerminalPanelID,
    in node: TerminalSplitLayout.Node
  ) -> [PathStep]? {
    pathToPanel(panelID, in: node, childIndex: 0)
  }

  private static func pathToPanel(
    _ panelID: TerminalPanelID,
    in node: TerminalSplitLayout.Node,
    childIndex: Int
  ) -> [PathStep]? {
    switch node {
    case .panel(let id):
      return id == panelID ? [PathStep(node: node, childIndex: childIndex)] : nil
    case .split(_, let children):
      for (index, child) in children.enumerated() {
        if let subPath = pathToPanel(panelID, in: child, childIndex: index) {
          return [PathStep(node: node, childIndex: childIndex)] + subPath
        }
      }
      return nil
    }
  }

  private static func descend(
    into node: TerminalSplitLayout.Node,
    from direction: TerminalPanelNavigationDirection
  ) -> TerminalPanelID? {
    switch node {
    case .panel(let id):
      return id
    case .split(let axis, let children):
      guard !children.isEmpty else { return nil }
      let target: TerminalSplitLayout.Node
      if axis == self.axis(for: direction) {
        target = isForward(direction) ? children.first! : children.last!
      } else {
        target = children.first!
      }
      return descend(into: target, from: direction)
    }
  }

  private static func axis(for direction: TerminalPanelNavigationDirection) -> TerminalSplitAxis {
    switch direction {
    case .left, .right: return .horizontal
    case .up, .down: return .vertical
    }
  }

  private static func isForward(_ direction: TerminalPanelNavigationDirection) -> Bool {
    switch direction {
    case .right, .down: return true
    case .left, .up: return false
    }
  }
}

private struct PathStep {
  let node: TerminalSplitLayout.Node
  let childIndex: Int
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
