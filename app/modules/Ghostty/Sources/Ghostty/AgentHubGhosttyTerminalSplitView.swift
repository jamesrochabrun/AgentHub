//
//  AgentHubGhosttyTerminalSplitView.swift
//  AgentHub
//

import AgentHubCore
import GhosttySwift
import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalSplitView: View {
  @State private var childRatios: [CGFloat] = []

  let node: TerminalSplitLayout.Node
  let session: TerminalSession
  let maximizedPanelID: TerminalPanelID?
  let canClosePanel: (TerminalPanel) -> Bool
  let canCloseTab: (TerminalPanel, TerminalTab) -> Bool
  let onActivatePanel: (TerminalPanel) -> Void
  let onSelectTab: (TerminalPanel, TerminalTab) -> Void
  let onClosePanel: (TerminalPanel) -> Void
  let onCloseTab: (TerminalPanel, TerminalTab) -> Void
  let onOpenTab: (TerminalPanel) -> Void
  let onSplitPanel: (TerminalPanel, TerminalSplitAxis) -> Void
  let onToggleMaximizedPanel: (TerminalPanel) -> Void
  let activityForPanel: (TerminalPanelID) -> AgentHubGhosttyTerminalPaneActivity?

  var body: some View {
    content(for: node)
  }

  @ViewBuilder
  private func content(for node: TerminalSplitLayout.Node) -> some View {
    switch node {
    case .panel(let panelID):
      if let panel = session.panel(for: panelID) {
        AgentHubGhosttyTerminalPaneView(
          panel: panel,
          session: session,
          isMaximized: panel.id == maximizedPanelID,
          showsSelectionBorder: session.visiblePanels.count > 1 && maximizedPanelID == nil,
          canMaximize: session.visiblePanels.count > 1,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          onToggleMaximizedPanel: onToggleMaximizedPanel,
          activity: activityForPanel(panel.id)
        )
      } else if let activity = activityForPanel(panelID) {
        AgentHubGhosttyPendingTerminalPaneView(activity: activity)
      } else {
        EmptyView()
      }

    case .split(let axis, let children):
      split(axis: axis, children: children)
    }
  }

  @ViewBuilder
  private func split(
    axis: TerminalSplitAxis,
    children: [TerminalSplitLayout.Node]
  ) -> some View {
    GeometryReader { proxy in
      switch axis {
      case .horizontal:
        horizontalSplit(children: children, size: proxy.size)
      case .vertical:
        verticalSplit(children: children, size: proxy.size)
      }
    }
  }

  private func horizontalSplit(
    children: [TerminalSplitLayout.Node],
    size: CGSize
  ) -> some View {
    let childWidths = TerminalPanelKit.SplitSizing.childDimensions(
      ratios: childRatios,
      childCount: children.count,
      containerLength: size.width,
      minimumChildDimension: TerminalPanelKit.SplitSizing.minimumChildDimension(for: .horizontal)
    )

    return HStack(spacing: 0) {
      ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
        if offset > 0 {
          divider(
            axis: .horizontal,
            dividerIndex: offset - 1,
            childCount: children.count,
            containerLength: size.width
          )
          .zIndex(1)
        }
        AgentHubGhosttyTerminalSplitView(
          node: child,
          session: session,
          maximizedPanelID: maximizedPanelID,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          onToggleMaximizedPanel: onToggleMaximizedPanel,
          activityForPanel: activityForPanel
        )
        .frame(width: childDimension(childWidths, at: offset), height: size.height)
        .zIndex(0)
      }
    }
    .onAppear {
      reconcileRatios(childCount: children.count)
    }
    .onChange(of: children.count) { _, childCount in
      reconcileRatios(childCount: childCount)
    }
  }

  private func verticalSplit(
    children: [TerminalSplitLayout.Node],
    size: CGSize
  ) -> some View {
    let childHeights = TerminalPanelKit.SplitSizing.childDimensions(
      ratios: childRatios,
      childCount: children.count,
      containerLength: size.height,
      minimumChildDimension: TerminalPanelKit.SplitSizing.minimumChildDimension(for: .vertical)
    )

    return VStack(spacing: 0) {
      ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
        if offset > 0 {
          divider(
            axis: .vertical,
            dividerIndex: offset - 1,
            childCount: children.count,
            containerLength: size.height
          )
          .zIndex(1)
        }
        AgentHubGhosttyTerminalSplitView(
          node: child,
          session: session,
          maximizedPanelID: maximizedPanelID,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          onToggleMaximizedPanel: onToggleMaximizedPanel,
          activityForPanel: activityForPanel
        )
        .frame(width: size.width, height: childDimension(childHeights, at: offset))
        .zIndex(0)
      }
    }
    .onAppear {
      reconcileRatios(childCount: children.count)
    }
    .onChange(of: children.count) { _, childCount in
      reconcileRatios(childCount: childCount)
    }
  }

  private func divider(
    axis: TerminalSplitAxis,
    dividerIndex: Int,
    childCount: Int,
    containerLength: CGFloat
  ) -> some View {
    let sizingAxis = TerminalPanelKit.SplitAxis(axis)
    return TerminalPanelSplitDivider(
      axis: sizingAxis,
      lineOpacity: 0.35,
      clampedTranslation: { translation in
        clampedResizeTranslation(
          axis: sizingAxis,
          dividerIndex: dividerIndex,
          childCount: childCount,
          containerLength: containerLength,
          translation: translation
        )
      },
      onCommitResize: { translation in
        commitResize(
          axis: sizingAxis,
          dividerIndex: dividerIndex,
          childCount: childCount,
          containerLength: containerLength,
          translation: translation
        )
      }
    )
  }

  private func childDimension(_ dimensions: [CGFloat], at index: Int) -> CGFloat {
    dimensions.indices.contains(index) ? dimensions[index] : 0
  }

  private func reconcileRatios(childCount: Int) {
    childRatios = TerminalPanelKit.SplitSizing.normalizedRatios(
      childRatios,
      childCount: childCount
    )
  }

  private func clampedResizeTranslation(
    axis: TerminalPanelKit.SplitAxis,
    dividerIndex: Int,
    childCount: Int,
    containerLength: CGFloat,
    translation: CGFloat
  ) -> CGFloat {
    TerminalPanelKit.SplitSizing.clampedResizeTranslation(
      from: TerminalPanelKit.SplitSizing.normalizedRatios(
        childRatios,
        childCount: childCount
      ),
      childCount: childCount,
      dividerIndex: dividerIndex,
      translation: translation,
      containerLength: containerLength,
      minimumChildDimension: TerminalPanelKit.SplitSizing.minimumChildDimension(for: axis)
    )
  }

  private func commitResize(
    axis: TerminalPanelKit.SplitAxis,
    dividerIndex: Int,
    childCount: Int,
    containerLength: CGFloat,
    translation: CGFloat
  ) {
    childRatios = TerminalPanelKit.SplitSizing.resizedRatios(
      from: TerminalPanelKit.SplitSizing.normalizedRatios(
        childRatios,
        childCount: childCount
      ),
      childCount: childCount,
      dividerIndex: dividerIndex,
      translation: translation,
      containerLength: containerLength,
      minimumChildDimension: TerminalPanelKit.SplitSizing.minimumChildDimension(for: axis)
    )
  }
}

private extension TerminalPanelKit.SplitAxis {
  init(_ axis: TerminalSplitAxis) {
    switch axis {
    case .horizontal:
      self = .horizontal
    case .vertical:
      self = .vertical
    }
  }
}
