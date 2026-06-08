//
//  GlobalSessionPanelDisplayModeToggleRelay.swift
//  AgentHubGlobalSessionPanel
//

import Observation

// MARK: - GlobalSessionPanelDisplayModeToggleRelay

/// Bridges the AppKit panel window's ⌘⌥/ key equivalent to the SwiftUI panel
/// view. The window can't mutate the view's `@State` directly, so it bumps a
/// request counter here that the view observes and acts on — mirroring how
/// `GlobalSessionSelectionRouter` carries selection requests into the view.
@MainActor
@Observable
public final class GlobalSessionPanelDisplayModeToggleRelay {
  public private(set) var toggleRequestCount = 0

  public init() {}

  public func requestToggle() {
    toggleRequestCount &+= 1
  }
}
