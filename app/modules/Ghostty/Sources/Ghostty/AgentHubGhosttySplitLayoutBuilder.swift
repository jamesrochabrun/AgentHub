//
//  AgentHubGhosttySplitLayoutBuilder.swift
//  AgentHub
//

import AgentHubCore
import CoreGraphics
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
        guard child.agentHubContainsPanel(anchorPanelID) else { return child }
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

  static func rearrangementProposal(
    root: TerminalSplitLayout.Node,
    dragging draggedPanelID: TerminalPanelID,
    over targetPanelID: TerminalPanelID,
    placement: TerminalPanelDropPlacement,
    containerSize: CGSize,
    minimumPanelSize: CGSize = TerminalPanelDragLayoutEngine.defaultMinimumPanelSize
  ) -> TerminalSplitLayout.Node? {
    TerminalPanelDragLayoutEngine.proposal(
      root: root.terminalPanelLayoutNode,
      dragging: draggedPanelID,
      over: targetPanelID,
      placement: placement,
      containerSize: containerSize,
      minimumPanelSize: minimumPanelSize
    ).map { TerminalSplitLayout.Node(layoutNode: $0.root) }
  }
}

extension TerminalSplitLayout.Node {
  var agentHubPanelIDs: [TerminalPanelID] {
    switch self {
    case .panel(let panelID):
      return [panelID]
    case .split(_, let children):
      return children.flatMap(\.agentHubPanelIDs)
    }
  }

  func agentHubContainsPanel(_ panelID: TerminalPanelID) -> Bool {
    switch self {
    case .panel(let currentPanelID):
      return currentPanelID == panelID
    case .split(_, let children):
      return children.contains { $0.agentHubContainsPanel(panelID) }
    }
  }

  init(layoutNode: TerminalPanelLayoutNode<TerminalPanelID>) {
    switch layoutNode {
    case .panel(let panelID):
      self = .panel(panelID)
    case .split(let axis, let children):
      self = .split(
        axis: TerminalSplitAxis(axis),
        children: children.map(TerminalSplitLayout.Node.init(layoutNode:))
      )
    }
  }

  var terminalPanelLayoutNode: TerminalPanelLayoutNode<TerminalPanelID> {
    switch self {
    case .panel(let panelID):
      return .panel(panelID)
    case .split(let axis, let children):
      return .split(
        axis: axis.terminalPanelLayoutAxis,
        children: children.map(\.terminalPanelLayoutNode)
      )
    }
  }
}

extension TerminalSplitAxis {
  init(_ axis: TerminalPanelLayoutAxis) {
    switch axis {
    case .horizontal:
      self = .horizontal
    case .vertical:
      self = .vertical
    }
  }

  var terminalPanelLayoutAxis: TerminalPanelLayoutAxis {
    switch self {
    case .horizontal:
      return .horizontal
    case .vertical:
      return .vertical
    }
  }
}
