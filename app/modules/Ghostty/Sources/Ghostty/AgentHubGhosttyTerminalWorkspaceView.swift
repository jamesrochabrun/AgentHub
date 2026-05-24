//
//  AgentHubGhosttyTerminalWorkspaceView.swift
//  AgentHub
//

import AgentHubCore
import GhosttySwift
import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalWorkspaceView: View {
  @State private var panelFrames: [TerminalPanelID: CGRect] = [:]
  @State private var dragState: AgentHubGhosttyPanelDragState?

  let session: TerminalSession
  let splitRoot: TerminalSplitLayout.Node?
  let canClosePanel: (TerminalPanel) -> Bool
  let canCloseTab: (TerminalPanel, TerminalTab) -> Bool
  let onActivatePanel: (TerminalPanel) -> Void
  let onSelectTab: (TerminalPanel, TerminalTab) -> Void
  let onClosePanel: (TerminalPanel) -> Void
  let onCloseTab: (TerminalPanel, TerminalTab) -> Void
  let onOpenTab: (TerminalPanel) -> Void
  let onSplitPanel: (TerminalPanel, TerminalSplitAxis) -> Void
  let onRearrangePanels: (TerminalSplitLayout.Node) -> Void
  let activityForPanel: (TerminalPanelID) -> AgentHubGhosttyTerminalPaneActivity?

  var body: some View {
    GeometryReader { proxy in
      if session.visiblePanels.isEmpty {
        Text("No terminal available")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        AgentHubGhosttyTerminalSplitView(
          node: displayedSplitRoot,
          session: session,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          dragVisualState: dragVisualState(for:),
          coordinateSpaceName: Self.coordinateSpaceName,
          onPanelDragChanged: { panel, value in
            updatePanelDrag(panel, value: value, containerSize: proxy.size)
          },
          onPanelDragEnded: { _, _ in
            finishPanelDrag()
          },
          activityForPanel: activityForPanel
        )
      }
    }
    .coordinateSpace(name: Self.coordinateSpaceName)
    .onPreferenceChange(AgentHubGhosttyPanelFramePreferenceKey.self) { frames in
      panelFrames = frames
    }
    .onChange(of: panelIdentity) { _, _ in
      dragState = nil
    }
  }

  private var resolvedSplitRoot: TerminalSplitLayout.Node {
    splitRoot ?? session.splitLayout?.root ?? .panel(session.primaryPanelID)
  }

  private var displayedSplitRoot: TerminalSplitLayout.Node {
    dragState?.proposalRoot ?? resolvedSplitRoot
  }

  private var panelIdentity: [TerminalPanelID] {
    session.visiblePanels.map(\.id)
  }

  private static let coordinateSpaceName = "AgentHubGhosttyWorkspaceCoordinateSpace"
  private static let nearestTargetDistance: CGFloat = 96

  private func updatePanelDrag(
    _ panel: TerminalPanel,
    value: DragGesture.Value,
    containerSize: CGSize
  ) {
    guard session.visiblePanels.count > 1 else { return }
    let sourceRoot = dragState?.sourceRoot ?? resolvedSplitRoot
    let sourceFrames = dragState?.sourceFrames ?? usablePanelFrames(
      containerSize: containerSize,
      root: sourceRoot
    )

    guard let target = targetPanel(at: value.location, dragging: panel.id, frames: sourceFrames) else {
      dragState = AgentHubGhosttyPanelDragState(
        draggedPanelID: panel.id,
        sourceRoot: sourceRoot,
        sourceFrames: sourceFrames,
        proposalRoot: nil,
        isInvalid: true
      )
      return
    }

    let placement = dropPlacement(for: value.location, in: target.frame)
    let proposalRoot = AgentHubGhosttySplitLayoutBuilder.rearrangementProposal(
      root: sourceRoot,
      dragging: panel.id,
      over: target.id,
      placement: placement,
      containerSize: containerSize
    )

    dragState = AgentHubGhosttyPanelDragState(
      draggedPanelID: panel.id,
      sourceRoot: sourceRoot,
      sourceFrames: sourceFrames,
      proposalRoot: proposalRoot,
      isInvalid: proposalRoot == nil
    )
  }

  private func finishPanelDrag() {
    defer { dragState = nil }
    guard let proposalRoot = dragState?.proposalRoot,
          dragState?.isInvalid == false else {
      return
    }
    onRearrangePanels(proposalRoot)
  }

  private func dragVisualState(for panelID: TerminalPanelID) -> TerminalPanelDragVisualState {
    guard dragState?.draggedPanelID == panelID else { return .inactive }
    return dragState?.isInvalid == true ? .invalid : .preview
  }

  private func targetPanel(
    at point: CGPoint,
    dragging draggedPanelID: TerminalPanelID,
    frames sourceFrames: [TerminalPanelID: CGRect]
  ) -> (id: TerminalPanelID, frame: CGRect)? {
    let frames = sourceFrames.filter { $0.key != draggedPanelID }
    guard !frames.isEmpty else { return nil }

    if let contained = frames.first(where: { $0.value.insetBy(dx: -12, dy: -12).contains(point) }) {
      return (contained.key, contained.value)
    }

    guard let nearest = frames.min(by: {
      distance(from: point, to: $0.value) < distance(from: point, to: $1.value)
    }) else {
      return nil
    }
    guard distance(from: point, to: nearest.value) <= Self.nearestTargetDistance else {
      return nil
    }
    return (nearest.key, nearest.value)
  }

  private func usablePanelFrames(
    containerSize: CGSize,
    root: TerminalSplitLayout.Node
  ) -> [TerminalPanelID: CGRect] {
    if !panelFrames.isEmpty {
      return panelFrames
    }
    return TerminalPanelDragLayoutEngine.panelFrames(
      for: root.terminalPanelLayoutNode,
      in: CGRect(origin: .zero, size: containerSize)
    )
  }

  private func dropPlacement(for point: CGPoint, in frame: CGRect) -> TerminalPanelDropPlacement {
    let distances: [(distance: CGFloat, placement: TerminalPanelDropPlacement)] = [
      (abs(point.x - frame.minX), .leading),
      (abs(point.x - frame.maxX), .trailing),
      (abs(point.y - frame.minY), .above),
      (abs(point.y - frame.maxY), .below)
    ]
    return distances.min(by: { $0.distance < $1.distance })?.placement ?? .trailing
  }

  private func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
    let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
    let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
    return sqrt(dx * dx + dy * dy)
  }
}

private struct AgentHubGhosttyPanelDragState {
  let draggedPanelID: TerminalPanelID
  let sourceRoot: TerminalSplitLayout.Node
  let sourceFrames: [TerminalPanelID: CGRect]
  let proposalRoot: TerminalSplitLayout.Node?
  let isInvalid: Bool
}

struct AgentHubGhosttyPanelFramePreferenceKey: PreferenceKey {
  static var defaultValue: [TerminalPanelID: CGRect] = [:]

  static func reduce(
    value: inout [TerminalPanelID: CGRect],
    nextValue: () -> [TerminalPanelID: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}
