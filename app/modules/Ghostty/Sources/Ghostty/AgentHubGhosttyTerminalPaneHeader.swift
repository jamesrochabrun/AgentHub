//
//  AgentHubGhosttyTerminalPaneHeader.swift
//  AgentHub
//

import GhosttySwift
import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalPaneHeader: View {
  let panel: TerminalPanel
  let isMaximized: Bool
  let canMaximize: Bool
  let canSplitRight: Bool
  let canSplitBelow: Bool
  let canClosePanel: Bool
  let canCloseTab: (TerminalTab) -> Bool
  let onSelectTab: (TerminalTab) -> Void
  let onCloseTab: (TerminalTab) -> Void
  let onOpenTab: () -> Void
  let onSplitRight: () -> Void
  let onSplitBelow: () -> Void
  let onToggleMaximizedPanel: () -> Void
  let onClosePanel: () -> Void

  var body: some View {
    ZStack(alignment: .bottom) {
      AgentHubGhosttyTerminalTabChrome.stripBackground

      Rectangle()
        .fill(AgentHubGhosttyTerminalTabChrome.divider)
        .frame(height: 1)

      HStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { index, tab in
              tabButton(tab: tab, index: index)
            }
          }
        }

        Spacer(minLength: 0)

        HStack(spacing: 2) {
          AgentHubGhosttyTerminalToolbarButton(
            title: "New Tab",
            systemImage: "plus",
            help: "New terminal tab",
            action: onOpenTab
          )

          if canMaximize {
            AgentHubGhosttyTerminalToolbarButton(
              title: isMaximized ? "Restore Pane" : "Maximize Pane",
              systemImage: isMaximized
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right",
              help: isMaximized
                ? "Restore terminal panes (Cmd+Shift+M)"
                : "Maximize terminal pane (Cmd+Shift+M)",
              action: onToggleMaximizedPanel
            )
          }

          AgentHubGhosttyTerminalToolbarButton(
            title: "Split Right",
            systemImage: "rectangle.split.2x1",
            help: "Split terminal to the right",
            isDisabled: !canSplitRight,
            action: onSplitRight
          )

          AgentHubGhosttyTerminalToolbarButton(
            title: "Split Below",
            systemImage: "rectangle.split.1x2",
            help: "Split terminal below",
            isDisabled: !canSplitBelow,
            action: onSplitBelow
          )

          if canClosePanel {
            AgentHubGhosttyTerminalToolbarButton(
              title: "Close Pane",
              systemImage: "xmark",
              help: "Close terminal pane",
              action: onClosePanel
            )
          }
        }
        .padding(.horizontal, 8)
      }
      .frame(height: AgentHubGhosttyTerminalTabChrome.stripHeight)
    }
    .frame(height: AgentHubGhosttyTerminalTabChrome.stripHeight)
  }

  private func tabButton(tab: TerminalTab, index: Int) -> some View {
    let isActive = tab.id == panel.activeTabID
    let title = tab.displayName(index: index)

    return AgentHubGhosttyTerminalTabItem(
      title: title,
      isActive: isActive,
      isFirst: index == 0,
      canClose: canCloseTab(tab),
      onSelect: { onSelectTab(tab) },
      onClose: { onCloseTab(tab) }
    )
  }
}
