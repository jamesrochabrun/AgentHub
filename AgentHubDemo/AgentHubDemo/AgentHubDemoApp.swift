//
//  AgentHubDemoApp.swift
//  AgentHubDemo
//
//  Created by James Rochabrun on 1/11/26.
//

import SwiftUI
import AgentHub

// MARK: - App Delegate

/// Handles app lifecycle events for process cleanup
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  /// Shared provider instance - created here so it's available for lifecycle events
  let provider = AgentHubProvider()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Note: We intentionally do NOT clean up orphaned processes here
    // because we can't distinguish between processes spawned by AgentHub
    // vs processes the user started directly in Terminal.app
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Terminate all active terminal processes on app quit
    provider.terminateAllTerminals()
  }
}

// MARK: - App

@main
struct AgentHubDemoApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup {
      AgentHubSessionsView()
        .agentHub(appDelegate.provider)
    }
    .windowStyle(.hiddenTitleBar)

    MenuBarExtra(
      isInserted: Binding(
        get: { appDelegate.provider.displaySettings.isMenuBarMode },
        set: { _ in }
      )
    ) {
      AgentHubMenuBarContent()
        .environment(\.agentHub, appDelegate.provider)
    } label: {
      AgentHubMenuBarLabel(provider: appDelegate.provider)
    }
    .menuBarExtraStyle(.window)
  }
}
