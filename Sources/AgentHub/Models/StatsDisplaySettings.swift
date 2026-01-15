//
//  StatsDisplaySettings.swift
//  AgentHub
//

import Foundation

/// Display mode for Claude Code stats
public enum StatsDisplayMode: String, CaseIterable, Sendable {
  case menuBar
  case popover
}

/// Settings for stats display configuration
@Observable
public final class StatsDisplaySettings {

  /// Current display mode for stats
  public let displayMode: StatsDisplayMode

  /// Whether menu bar mode is active
  public var isMenuBarMode: Bool {
    displayMode == .menuBar
  }

  /// Whether popover mode is active
  public var isPopoverMode: Bool {
    displayMode == .popover
  }

  public init(_ mode: StatsDisplayMode = .menuBar) {
    self.displayMode = mode
  }
}
