//
//  SimulatorAppHider.swift
//  AgentHub
//
//  Keeps the real Simulator.app window out of the way while the side panel
//  mirrors the device: the panel IS the display, so showing both is
//  duplicate noise. Hiding uses public `NSRunningApplication.hide()` — the
//  same ⌘H the user could press — so the app (and every booted device in it)
//  keeps running untouched and stays one ⌘Tab away. Never terminates
//  anything, needs no permissions.
//

import AppKit

@MainActor
public protocol SimulatorAppHiding: AnyObject {
  /// Hides Simulator.app if it is running. No-op otherwise.
  func hideSimulatorApp()
}

@MainActor
public final class SimulatorAppHider: SimulatorAppHiding {
  public static let shared = SimulatorAppHider()

  static let simulatorBundleIdentifier = "com.apple.iphonesimulator"

  public init() {}

  public func hideSimulatorApp() {
    let running = NSRunningApplication.runningApplications(
      withBundleIdentifier: Self.simulatorBundleIdentifier
    )
    for application in running where !application.isHidden {
      application.hide()
    }
  }
}
