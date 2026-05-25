//
//  AgentHubGhosttyTerminalWorkspaceView.swift
//  AgentHub
//

import GhosttySwift
import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalWorkspaceView: View {
  let session: TerminalSession
  let splitRoot: TerminalSplitLayout.Node?
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
    if session.visiblePanels.isEmpty {
      Text("No terminal available")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      AgentHubGhosttyTerminalSplitView(
        node: resolvedSplitRoot,
        session: session,
        maximizedPanelID: effectiveMaximizedPanelID,
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
    }
  }

  private var resolvedSplitRoot: TerminalSplitLayout.Node {
    if let effectiveMaximizedPanelID {
      return .panel(effectiveMaximizedPanelID)
    }
    return splitRoot ?? session.splitLayout?.root ?? .panel(session.primaryPanelID)
  }

  private var effectiveMaximizedPanelID: TerminalPanelID? {
    guard let maximizedPanelID, session.panel(for: maximizedPanelID) != nil else {
      return nil
    }
    return maximizedPanelID
  }
}
