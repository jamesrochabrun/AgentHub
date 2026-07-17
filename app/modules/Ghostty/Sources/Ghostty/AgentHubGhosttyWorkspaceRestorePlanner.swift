//
//  AgentHubGhosttyWorkspaceRestorePlanner.swift
//  Ghostty
//
//  Pure planning for rebuilding workspace panels from a persisted snapshot.
//  Restore must never silently drop a tab that carries a linked session:
//  once a tab is missing from the rebuilt surface, the next workspace-changed
//  reconcile deletes its session link from the database permanently.
//

import AgentHubCore

enum AgentHubGhosttyWorkspaceRestorePlanner {

  struct PrimaryPlan: Equatable {
    /// Snapshot tabs to open as new tabs, in order.
    let tabsToOpen: [TerminalWorkspaceTabSnapshot]
    /// True when the surface's pre-existing tab stands in for the snapshot's
    /// first tab. False means every snapshot tab is opened anew and the
    /// pre-created placeholder shell is redundant.
    let reusesExistingTab: Bool
  }

  struct AuxiliaryPlan: Equatable {
    /// Tab restored together with the panel itself.
    let anchorTab: TerminalWorkspaceTabSnapshot
    /// Remaining tabs opened after the anchor, in order.
    let additionalTabs: [TerminalWorkspaceTabSnapshot]
  }

  static func primaryPlan(
    for panel: TerminalWorkspacePanelSnapshot,
    hasProtectedAgentTab: Bool
  ) -> PrimaryPlan {
    if hasProtectedAgentTab {
      // The retained protected agent tab stands in for the snapshot's own
      // protected tab (captured as an unlinked agent tab), so only plain
      // shells and linked agent tabs are recreated.
      return PrimaryPlan(
        tabsToOpen: panel.tabs.filter { $0.role == .shell || $0.linkedSession != nil },
        reusesExistingTab: true
      )
    }

    // Neutral workspace: the pre-created placeholder is a plain shell, so it
    // may only stand in for a leading plain-shell tab — never for an agent
    // tab whose linked session would otherwise be lost.
    let reusesExistingTab = panel.tabs.first.map(isPlainShell) ?? false
    return PrimaryPlan(
      tabsToOpen: reusesExistingTab ? Array(panel.tabs.dropFirst()) : panel.tabs,
      reusesExistingTab: reusesExistingTab
    )
  }

  static func auxiliaryPlan(
    for panel: TerminalWorkspacePanelSnapshot
  ) -> AuxiliaryPlan? {
    var tabs = panel.tabs
    guard !tabs.isEmpty else { return nil }
    let anchorTab = tabs.removeFirst()
    return AuxiliaryPlan(anchorTab: anchorTab, additionalTabs: tabs)
  }

  /// An agent tab without a linked session has no session identity to resume;
  /// it restores as a plain shell in its working directory so the pane
  /// layout survives instead of vanishing.
  static func isPlainShell(_ tab: TerminalWorkspaceTabSnapshot) -> Bool {
    tab.role == .shell && tab.linkedSession == nil
  }
}
