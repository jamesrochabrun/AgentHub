//
//  AgentHubGhosttyTerminalPaneView.swift
//  AgentHub
//

import GhosttySwift
import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalPaneView: View {
  @State private var immediateActivity: AgentHubGhosttyTerminalPaneActivity?

  let panel: TerminalPanel
  let session: TerminalSession
  let canClosePanel: (TerminalPanel) -> Bool
  let canCloseTab: (TerminalPanel, TerminalTab) -> Bool
  let onActivatePanel: (TerminalPanel) -> Void
  let onSelectTab: (TerminalPanel, TerminalTab) -> Void
  let onClosePanel: (TerminalPanel) -> Void
  let onCloseTab: (TerminalPanel, TerminalTab) -> Void
  let onOpenTab: (TerminalPanel) -> Void
  let onSplitPanel: (TerminalPanel, TerminalSplitAxis) -> Void
  let activity: AgentHubGhosttyTerminalPaneActivity?

  var body: some View {
    VStack(spacing: 0) {
      AgentHubGhosttyTerminalPaneHeader(
        panel: panel,
        canSplit: session.canOpenPanel,
        canClosePanel: canClosePanel(panel),
        canCloseTab: { tab in canCloseTab(panel, tab) },
        onSelectTab: { tab in onSelectTab(panel, tab) },
        onCloseTab: closeTab,
        onOpenTab: { onOpenTab(panel) },
        onSplitRight: { onSplitPanel(panel, .horizontal) },
        onSplitBelow: { onSplitPanel(panel, .vertical) },
        onClosePanel: closePanel
      )

      if let activeTab = panel.activeTab {
        ZStack {
          AgentHubGhosttyTerminalContainerRepresentable(tab: activeTab)
            .id(activeTab.id)

          if let visibleActivity {
            AgentHubGhosttyTerminalPaneActivityOverlay(activity: visibleActivity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text("No tab available")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
    .overlay {
      if panel.id == session.activePanelID && session.visiblePanels.count > 1 {
        Rectangle()
          .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
      }
    }
    .onChange(of: activity) { _, newActivity in
      if newActivity == nil {
        immediateActivity = nil
      }
    }
  }

  private var visibleActivity: AgentHubGhosttyTerminalPaneActivity? {
    immediateActivity ?? activity
  }

  private func closePanel() {
    guard immediateActivity == nil else { return }
    immediateActivity = .closingPanel
    Task { @MainActor in
      await Task.yield()
      onClosePanel(panel)
    }
  }

  private func closeTab(_ tab: TerminalTab) {
    guard immediateActivity == nil else { return }
    immediateActivity = .closingTerminal
    Task { @MainActor in
      await Task.yield()
      onCloseTab(panel, tab)
    }
  }
}
