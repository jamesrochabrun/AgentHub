//
//  EmbeddedSidePanelSidebarVisibilityState.swift
//  AgentHub
//

import SwiftUI

struct EmbeddedSidePanelSidebarVisibilityState {
  private(set) var isEmbeddedTrailingPanelVisible = false
  private(set) var sidebarVisibilityBeforeAutoHide: NavigationSplitViewVisibility?

  mutating func resetAutoHideState() {
    sidebarVisibilityBeforeAutoHide = nil
  }

  mutating func columnVisibilityChange(
    forEmbeddedSidePanelVisible isVisible: Bool,
    currentColumnVisibility: NavigationSplitViewVisibility
  ) -> NavigationSplitViewVisibility? {
    guard isEmbeddedTrailingPanelVisible != isVisible else { return nil }
    isEmbeddedTrailingPanelVisible = isVisible

    if isVisible {
      guard currentColumnVisibility != .detailOnly else {
        sidebarVisibilityBeforeAutoHide = nil
        return nil
      }

      sidebarVisibilityBeforeAutoHide = currentColumnVisibility
      return .detailOnly
    }

    guard let previousVisibility = sidebarVisibilityBeforeAutoHide else { return nil }
    sidebarVisibilityBeforeAutoHide = nil

    guard currentColumnVisibility == .detailOnly else { return nil }
    return previousVisibility
  }
}
