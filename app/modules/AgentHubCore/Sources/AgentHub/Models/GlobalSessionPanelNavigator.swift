//
//  GlobalSessionPanelNavigator.swift
//  AgentHub
//

import Foundation

// MARK: - GlobalSessionListNavigationDirection

public enum GlobalSessionListNavigationDirection: Sendable {
  case up
  case down
}

// MARK: - GlobalSessionPanelNavigator

/// Pure keyboard-navigation math for the global session control panel list.
///
/// Selection clamps at the list edges (it does not wrap). When nothing is
/// selected yet, moving down lands on the first row and moving up lands on the
/// last row, so the first arrow press always selects a visible row.
public enum GlobalSessionPanelNavigator {
  public static func nextSelection(
    currentID: String?,
    direction: GlobalSessionListNavigationDirection,
    itemIDs: [String]
  ) -> String? {
    guard !itemIDs.isEmpty else { return nil }

    guard let currentID, let index = itemIDs.firstIndex(of: currentID) else {
      return direction == .down ? itemIDs.first : itemIDs.last
    }

    switch direction {
    case .up:
      return index > 0 ? itemIDs[index - 1] : itemIDs[index]
    case .down:
      return index < itemIDs.count - 1 ? itemIDs[index + 1] : itemIDs[index]
    }
  }

  /// Returns a still-valid selection after the visible list changes. Keeps the
  /// current selection when it still exists, otherwise falls back to the first
  /// row (or `nil` when the list is empty).
  public static func validatedSelection(
    currentID: String?,
    itemIDs: [String]
  ) -> String? {
    guard !itemIDs.isEmpty else { return nil }
    if let currentID, itemIDs.contains(currentID) { return currentID }
    return itemIDs.first
  }
}
