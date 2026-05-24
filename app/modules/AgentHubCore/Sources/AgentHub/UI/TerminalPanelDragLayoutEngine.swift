//
//  TerminalPanelDragLayoutEngine.swift
//  AgentHub
//

import CoreGraphics
import Foundation

public enum TerminalPanelLayoutAxis: Codable, Equatable, Sendable {
  case horizontal
  case vertical

  public var opposite: TerminalPanelLayoutAxis {
    switch self {
    case .horizontal:
      return .vertical
    case .vertical:
      return .horizontal
    }
  }
}

public enum TerminalPanelDropPlacement: Equatable, Sendable {
  case leading
  case trailing
  case above
  case below

  public var axis: TerminalPanelLayoutAxis {
    switch self {
    case .leading, .trailing:
      return .horizontal
    case .above, .below:
      return .vertical
    }
  }

  var order: TerminalPanelLayoutInsertionOrder {
    switch self {
    case .leading, .above:
      return .before
    case .trailing, .below:
      return .after
    }
  }
}

public enum TerminalPanelDragVisualState: Equatable, Sendable {
  case inactive
  case preview
  case invalid
}

public indirect enum TerminalPanelLayoutNode<PanelID: Hashable>: Equatable {
  case panel(PanelID)
  case split(axis: TerminalPanelLayoutAxis, children: [TerminalPanelLayoutNode<PanelID>])

  public var panelIDs: [PanelID] {
    switch self {
    case .panel(let panelID):
      return [panelID]
    case .split(_, let children):
      return children.flatMap(\.panelIDs)
    }
  }

  public func containsPanel(_ panelID: PanelID) -> Bool {
    switch self {
    case .panel(let currentPanelID):
      return currentPanelID == panelID
    case .split(_, let children):
      return children.contains { $0.containsPanel(panelID) }
    }
  }

  public func removingPanel(_ panelID: PanelID) -> TerminalPanelLayoutNode<PanelID>? {
    switch self {
    case .panel(let currentPanelID):
      return currentPanelID == panelID ? nil : self

    case .split(let axis, let children):
      let remainingChildren = children.compactMap { $0.removingPanel(panelID) }
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

  public func insertingPanel(
    _ panelID: PanelID,
    beside targetPanelID: PanelID,
    axis insertionAxis: TerminalPanelLayoutAxis,
    order: TerminalPanelLayoutInsertionOrder
  ) -> TerminalPanelLayoutNode<PanelID> {
    switch self {
    case .panel(let currentPanelID):
      guard currentPanelID == targetPanelID else { return self }
      return Self.split(
        axis: insertionAxis,
        children: order.ordered(panelID, targetPanelID).map(Self.panel)
      )

    case .split(let axis, let children):
      if axis == insertionAxis,
         let directTargetIndex = children.firstIndex(where: { $0.directPanelID == targetPanelID }) {
        var updatedChildren = children
        let insertionIndex = order == .before ? directTargetIndex : directTargetIndex + 1
        updatedChildren.insert(.panel(panelID), at: insertionIndex)
        return .split(axis: axis, children: updatedChildren)
      }

      return .split(
        axis: axis,
        children: children.map { child in
          guard child.containsPanel(targetPanelID) else { return child }
          return child.insertingPanel(
            panelID,
            beside: targetPanelID,
            axis: insertionAxis,
            order: order
          )
        }
      )
    }
  }

  var directPanelID: PanelID? {
    switch self {
    case .panel(let panelID):
      return panelID
    case .split:
      return nil
    }
  }
}

public enum TerminalPanelLayoutInsertionOrder: Equatable, Sendable {
  case before
  case after

  func ordered<PanelID>(_ panelID: PanelID, _ targetPanelID: PanelID) -> [PanelID] {
    switch self {
    case .before:
      return [panelID, targetPanelID]
    case .after:
      return [targetPanelID, panelID]
    }
  }
}

public struct TerminalPanelLayoutProposal<PanelID: Hashable>: Equatable {
  public let root: TerminalPanelLayoutNode<PanelID>
  public let frames: [PanelID: CGRect]
  public let switchedAxis: Bool

  public init(
    root: TerminalPanelLayoutNode<PanelID>,
    frames: [PanelID: CGRect],
    switchedAxis: Bool
  ) {
    self.root = root
    self.frames = frames
    self.switchedAxis = switchedAxis
  }
}

public enum TerminalPanelDragLayoutEngine {
  public static let defaultMinimumPanelSize = CGSize(width: 260, height: 160)
  public static let defaultDividerSize: CGFloat = 1

  public static func proposal<PanelID: Hashable>(
    root: TerminalPanelLayoutNode<PanelID>,
    dragging draggedPanelID: PanelID,
    over targetPanelID: PanelID,
    placement: TerminalPanelDropPlacement,
    containerSize: CGSize,
    minimumPanelSize: CGSize = defaultMinimumPanelSize,
    dividerSize: CGFloat = defaultDividerSize
  ) -> TerminalPanelLayoutProposal<PanelID>? {
    guard draggedPanelID != targetPanelID,
          containerSize.width > 0,
          containerSize.height > 0,
          root.containsPanel(draggedPanelID),
          root.containsPanel(targetPanelID),
          let rootWithoutDragged = root.removingPanel(draggedPanelID),
          rootWithoutDragged.containsPanel(targetPanelID) else {
      return nil
    }

    let expectedPanelIDs = root.panelIDs
    let candidates = proposalCandidates(
      rootWithoutDragged: rootWithoutDragged,
      draggedPanelID: draggedPanelID,
      targetPanelID: targetPanelID,
      placement: placement
    )

    for candidate in candidates {
      guard exactPanelSet(candidate.root, matches: expectedPanelIDs) else { continue }
      let frames = panelFrames(
        for: candidate.root,
        in: CGRect(origin: .zero, size: containerSize),
        dividerSize: dividerSize
      )
      guard framesSatisfyMinimum(
        frames,
        panelIDs: expectedPanelIDs,
        minimumPanelSize: minimumPanelSize
      ) else {
        continue
      }
      return TerminalPanelLayoutProposal(
        root: candidate.root,
        frames: frames,
        switchedAxis: candidate.switchedAxis
      )
    }

    return nil
  }

  public static func panelFrames<PanelID: Hashable>(
    for node: TerminalPanelLayoutNode<PanelID>,
    in rect: CGRect,
    dividerSize: CGFloat = defaultDividerSize
  ) -> [PanelID: CGRect] {
    switch node {
    case .panel(let panelID):
      return [panelID: rect]
    case .split(let axis, let children):
      return splitPanelFrames(axis: axis, children: children, in: rect, dividerSize: dividerSize)
    }
  }

  private static func proposalCandidates<PanelID: Hashable>(
    rootWithoutDragged: TerminalPanelLayoutNode<PanelID>,
    draggedPanelID: PanelID,
    targetPanelID: PanelID,
    placement: TerminalPanelDropPlacement
  ) -> [(root: TerminalPanelLayoutNode<PanelID>, switchedAxis: Bool)] {
    var candidates: [(root: TerminalPanelLayoutNode<PanelID>, switchedAxis: Bool)] = []

    if let flatRoot = flatRootCandidate(
      rootWithoutDragged: rootWithoutDragged,
      draggedPanelID: draggedPanelID,
      targetPanelID: targetPanelID,
      placement: placement,
      switchedAxis: false
    ) {
      append((root: flatRoot.root, switchedAxis: flatRoot.switchedAxis), to: &candidates)
      let reflowedRoot = TerminalPanelLayoutNode.split(
        axis: flatRoot.rootAxis.opposite,
        children: flatRoot.children
      )
      append((root: reflowedRoot, switchedAxis: true), to: &candidates)
    }

    let edgeCandidate = rootWithoutDragged.insertingPanel(
      draggedPanelID,
      beside: targetPanelID,
      axis: placement.axis,
      order: placement.order
    )
    append((root: edgeCandidate, switchedAxis: false), to: &candidates)

    return candidates
  }

  private static func flatRootCandidate<PanelID: Hashable>(
    rootWithoutDragged: TerminalPanelLayoutNode<PanelID>,
    draggedPanelID: PanelID,
    targetPanelID: PanelID,
    placement: TerminalPanelDropPlacement,
    switchedAxis: Bool
  ) -> (root: TerminalPanelLayoutNode<PanelID>, rootAxis: TerminalPanelLayoutAxis, children: [TerminalPanelLayoutNode<PanelID>], switchedAxis: Bool)? {
    switch rootWithoutDragged {
    case .panel(let panelID):
      guard panelID == targetPanelID else { return nil }
      let children = placement.order.ordered(draggedPanelID, targetPanelID).map(TerminalPanelLayoutNode.panel)
      return (
        root: .split(axis: placement.axis, children: children),
        rootAxis: placement.axis,
        children: children,
        switchedAxis: switchedAxis
      )

    case .split(let axis, let children):
      guard children.allSatisfy({ $0.directPanelID != nil }),
            children.contains(where: { $0.directPanelID == targetPanelID }) else {
        return nil
      }
      var updatedChildren = children
      guard let targetIndex = updatedChildren.firstIndex(where: { $0.directPanelID == targetPanelID }) else {
        return nil
      }
      let insertionIndex = placement.order == .before ? targetIndex : targetIndex + 1
      updatedChildren.insert(.panel(draggedPanelID), at: insertionIndex)
      return (
        root: .split(axis: axis, children: updatedChildren),
        rootAxis: axis,
        children: updatedChildren,
        switchedAxis: switchedAxis
      )
    }
  }

  private static func append<PanelID: Hashable>(
    _ candidate: (root: TerminalPanelLayoutNode<PanelID>, switchedAxis: Bool),
    to candidates: inout [(root: TerminalPanelLayoutNode<PanelID>, switchedAxis: Bool)]
  ) {
    guard !candidates.contains(where: { $0.root == candidate.root }) else { return }
    candidates.append(candidate)
  }

  private static func splitPanelFrames<PanelID: Hashable>(
    axis: TerminalPanelLayoutAxis,
    children: [TerminalPanelLayoutNode<PanelID>],
    in rect: CGRect,
    dividerSize: CGFloat
  ) -> [PanelID: CGRect] {
    guard !children.isEmpty else { return [:] }

    var result: [PanelID: CGRect] = [:]
    let childCount = CGFloat(children.count)

    switch axis {
    case .horizontal:
      let totalDividerWidth = dividerSize * CGFloat(max(children.count - 1, 0))
      let childWidth = max(0, rect.width - totalDividerWidth) / childCount
      var nextX = rect.minX

      for (index, child) in children.enumerated() {
        if index > 0 {
          nextX += dividerSize
        }
        let childRect = CGRect(x: nextX, y: rect.minY, width: childWidth, height: rect.height)
        result.merge(
          panelFrames(for: child, in: childRect, dividerSize: dividerSize),
          uniquingKeysWith: { current, _ in current }
        )
        nextX += childWidth
      }

    case .vertical:
      let totalDividerHeight = dividerSize * CGFloat(max(children.count - 1, 0))
      let childHeight = max(0, rect.height - totalDividerHeight) / childCount
      var nextY = rect.minY

      for (index, child) in children.enumerated() {
        if index > 0 {
          nextY += dividerSize
        }
        let childRect = CGRect(x: rect.minX, y: nextY, width: rect.width, height: childHeight)
        result.merge(
          panelFrames(for: child, in: childRect, dividerSize: dividerSize),
          uniquingKeysWith: { current, _ in current }
        )
        nextY += childHeight
      }
    }

    return result
  }

  private static func framesSatisfyMinimum<PanelID: Hashable>(
    _ frames: [PanelID: CGRect],
    panelIDs: [PanelID],
    minimumPanelSize: CGSize
  ) -> Bool {
    for panelID in panelIDs {
      guard let frame = frames[panelID],
            frame.width >= minimumPanelSize.width,
            frame.height >= minimumPanelSize.height else {
        return false
      }
    }
    return true
  }

  private static func exactPanelSet<PanelID: Hashable>(
    _ node: TerminalPanelLayoutNode<PanelID>,
    matches panelIDs: [PanelID]
  ) -> Bool {
    let nodePanelIDs = node.panelIDs
    return nodePanelIDs.count == panelIDs.count && Set(nodePanelIDs) == Set(panelIDs)
  }
}
