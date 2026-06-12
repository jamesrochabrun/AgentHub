import SwiftUI
import Testing

@testable import AgentHubCore

@Suite("EmbeddedSidePanelSidebarVisibilityState")
struct EmbeddedSidePanelSidebarVisibilityStateTests {
  @Test("Opening embedded side panel hides visible sidebar and records previous visibility")
  func openingEmbeddedSidePanelHidesVisibleSidebar() {
    var state = EmbeddedSidePanelSidebarVisibilityState()

    let change = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: true,
      currentColumnVisibility: .all
    )

    #expect(change == .detailOnly)
    #expect(state.isEmbeddedTrailingPanelVisible)
    #expect(state.sidebarVisibilityBeforeAutoHide == .all)
  }

  @Test("Closing embedded side panel restores the visibility auto-hidden on open")
  func closingEmbeddedSidePanelRestoresAutoHiddenSidebar() {
    var state = EmbeddedSidePanelSidebarVisibilityState()
    _ = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: true,
      currentColumnVisibility: .all
    )

    let change = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: false,
      currentColumnVisibility: .detailOnly
    )

    #expect(change == .all)
    #expect(!state.isEmbeddedTrailingPanelVisible)
    #expect(state.sidebarVisibilityBeforeAutoHide == nil)
  }

  @Test("Opening embedded side panel while sidebar is already hidden does not restore it later")
  func alreadyHiddenSidebarIsNotRestoredOnClose() {
    var state = EmbeddedSidePanelSidebarVisibilityState()

    let openChange = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: true,
      currentColumnVisibility: .detailOnly
    )
    let closeChange = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: false,
      currentColumnVisibility: .detailOnly
    )

    #expect(openChange == nil)
    #expect(closeChange == nil)
    #expect(!state.isEmbeddedTrailingPanelVisible)
    #expect(state.sidebarVisibilityBeforeAutoHide == nil)
  }

  @Test("Duplicate visibility updates are ignored")
  func duplicateVisibilityUpdatesAreIgnored() {
    var state = EmbeddedSidePanelSidebarVisibilityState()
    _ = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: true,
      currentColumnVisibility: .all
    )

    let duplicateChange = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: true,
      currentColumnVisibility: .detailOnly
    )

    #expect(duplicateChange == nil)
    #expect(state.sidebarVisibilityBeforeAutoHide == .all)
  }

  @Test("Manual sidebar toggle clears pending auto restore")
  func resetClearsPendingAutoRestore() {
    var state = EmbeddedSidePanelSidebarVisibilityState()
    _ = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: true,
      currentColumnVisibility: .all
    )

    state.resetAutoHideState()
    let closeChange = state.columnVisibilityChange(
      forEmbeddedSidePanelVisible: false,
      currentColumnVisibility: .detailOnly
    )

    #expect(closeChange == nil)
    #expect(!state.isEmbeddedTrailingPanelVisible)
    #expect(state.sidebarVisibilityBeforeAutoHide == nil)
  }
}
