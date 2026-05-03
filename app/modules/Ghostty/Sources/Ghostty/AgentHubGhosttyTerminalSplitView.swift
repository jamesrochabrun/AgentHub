//
//  AgentHubGhosttyTerminalSplitView.swift
//  AgentHub
//

import GhosttySwift
import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalSplitView: View {
  let node: TerminalSplitLayout.Node
  let session: TerminalSession
  let canClosePanel: (TerminalPanel) -> Bool
  let canCloseTab: (TerminalPanel, TerminalTab) -> Bool
  let onActivatePanel: (TerminalPanel) -> Void
  let onSelectTab: (TerminalPanel, TerminalTab) -> Void
  let onClosePanel: (TerminalPanel) -> Void
  let onCloseTab: (TerminalPanel, TerminalTab) -> Void
  let onOpenTab: (TerminalPanel) -> Void
  let onSplitPanel: (TerminalPanel, TerminalSplitAxis) -> Void
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
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
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
    let dividerSize: CGFloat = 1
    let childCount = CGFloat(max(children.count, 1))
    let totalDividerWidth = dividerSize * CGFloat(max(children.count - 1, 0))
    let childWidth = max(0, size.width - totalDividerWidth) / childCount

    return HStack(spacing: 0) {
      ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
        if offset > 0 {
          divider(axis: .horizontal)
        }
        AgentHubGhosttyTerminalSplitView(
          node: child,
          session: session,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          activityForPanel: activityForPanel
        )
        .frame(width: childWidth, height: size.height)
      }
    }
  }

  private func verticalSplit(
    children: [TerminalSplitLayout.Node],
    size: CGSize
  ) -> some View {
    let dividerSize: CGFloat = 1
    let childCount = CGFloat(max(children.count, 1))
    let totalDividerHeight = dividerSize * CGFloat(max(children.count - 1, 0))
    let childHeight = max(0, size.height - totalDividerHeight) / childCount

    return VStack(spacing: 0) {
      ForEach(Array(children.enumerated()), id: \.offset) { offset, child in
        if offset > 0 {
          divider(axis: .vertical)
        }
        AgentHubGhosttyTerminalSplitView(
          node: child,
          session: session,
          canClosePanel: canClosePanel,
          canCloseTab: canCloseTab,
          onActivatePanel: onActivatePanel,
          onSelectTab: onSelectTab,
          onClosePanel: onClosePanel,
          onCloseTab: onCloseTab,
          onOpenTab: onOpenTab,
          onSplitPanel: onSplitPanel,
          activityForPanel: activityForPanel
        )
        .frame(width: size.width, height: childHeight)
      }
    }
  }

  @ViewBuilder
  private func divider(axis: TerminalSplitAxis) -> some View {
    switch axis {
    case .horizontal:
      Color.primary.opacity(0.35)
        .frame(width: 1)
    case .vertical:
      Color.primary.opacity(0.35)
        .frame(height: 1)
    }
  }
}
