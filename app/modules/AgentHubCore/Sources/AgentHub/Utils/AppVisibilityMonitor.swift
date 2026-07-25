//
//  AppVisibilityMonitor.swift
//  AgentHub
//
//  App-level occlusion state, so repeating animations can stop when nobody
//  can see them.
//

import AppKit
import Observation

/// Tracks whether any of the app's windows are actually visible on screen.
///
/// AppKit posts `didChangeOcclusionState` when the app's windows become fully
/// covered, minimized, or hidden. Nothing in AgentHub used to observe it, so the
/// `repeatForever` status pulses kept the SwiftUI display link — and with it the
/// per-frame CoreAnimation commit and view-graph update — running for the whole
/// time an agent was working, visible or not. Sessions are long-running and
/// often left in the background, so that is a battery cost with no user-visible
/// benefit.
///
/// Views read `isVisible` and stop their repeating animations when it is false.
@MainActor
@Observable
public final class AppVisibilityMonitor {
  /// `true` while at least one app window is on screen and unoccluded.
  public private(set) var isVisible: Bool

  @ObservationIgnored private var observer: (any NSObjectProtocol)?

  /// - Parameters:
  ///   - isVisible: Seed value. Defaults to the application's current occlusion
  ///     state when observing, so a monitor created while hidden starts correct.
  ///   - observesApplication: Pass `false` in tests to get a monitor that only
  ///     changes through `setVisible(_:)`.
  public init(isVisible: Bool? = nil, observesApplication: Bool = true) {
    self.isVisible = isVisible
      ?? (observesApplication ? NSApplication.shared.occlusionState.contains(.visible) : true)

    guard observesApplication else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeOcclusionStateNotification,
      object: NSApplication.shared,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.setVisible(NSApplication.shared.occlusionState.contains(.visible))
      }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Write-on-change: this feeds `@Observable` invalidation, and the
  /// notification fires for transitions we may already reflect.
  public func setVisible(_ newValue: Bool) {
    guard isVisible != newValue else { return }
    isVisible = newValue
  }
}

// MARK: - Pulse policy

/// Whether a status pulse animation should be running.
///
/// Split out from the views so the rule is testable without AppKit windows.
public enum StatusPulsePolicy {
  public static func shouldPulse(isActiveStatus: Bool, isAppVisible: Bool) -> Bool {
    isActiveStatus && isAppVisible
  }
}
