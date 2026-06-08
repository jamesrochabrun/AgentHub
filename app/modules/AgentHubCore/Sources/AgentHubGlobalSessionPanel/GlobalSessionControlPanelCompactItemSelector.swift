//
//  GlobalSessionControlPanelCompactItemSelector.swift
//  AgentHubGlobalSessionPanel
//

import Foundation
import AgentHubCore

// MARK: - GlobalSessionControlPanelCompactItemSelector

public enum GlobalSessionControlPanelCompactItemSelector {
  public static func featuredItem(
    from items: [GlobalSessionControlPanelItem]
  ) -> GlobalSessionControlPanelItem? {
    let activeItems = items.filter(isActiveCandidate)
    return recencySorted(activeItems.isEmpty ? items : activeItems).first
  }

  private static func isActiveCandidate(_ item: GlobalSessionControlPanelItem) -> Bool {
    if item.isPending || item.session.isActive {
      return true
    }

    guard let status = item.status else {
      return false
    }

    switch status {
    case .thinking, .executingTool, .waitingForUser, .awaitingApproval:
      return true
    case .idle:
      return false
    }
  }

  private static func recencySorted(
    _ items: [GlobalSessionControlPanelItem]
  ) -> [GlobalSessionControlPanelItem] {
    items.sorted { lhs, rhs in
      if lhs.timestamp != rhs.timestamp {
        return lhs.timestamp > rhs.timestamp
      }
      if lhs.providerKind != rhs.providerKind {
        return lhs.providerKind.rawValue < rhs.providerKind.rawValue
      }
      let displayNameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
      if displayNameComparison != .orderedSame {
        return displayNameComparison == .orderedAscending
      }
      return lhs.id < rhs.id
    }
  }
}
