//
//  AgentHubApp.swift
//  AgentHub
//
//  Created by James Rochabrun on 1/11/26.
//

import SwiftUI
import AgentHubCore

// MARK: - App Delegate

/// Handles app lifecycle events for process cleanup
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  /// Shared provider instance - created here so it's available for lifecycle events
  let provider = AgentHubProvider()

  /// Update controller for Sparkle auto-updates
  let updateController = UpdateController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Note: We intentionally do NOT clean up orphaned processes here
    // because we can't distinguish between processes spawned by AgentHub
    // vs processes the user started directly in Terminal.app
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Terminate all active terminal processes on app quit
    provider.terminateAllTerminals()
    // Stop all dev servers spawned for web preview
    DevServerManager.shared.stopAllServers()
  }
}

// MARK: - App

@main
struct AgentHubApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    WindowGroup {
      AgentHubSessionsView()
        .agentHub(appDelegate.provider)
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .appInfo) {
        CheckForUpdatesView(updateController: appDelegate.updateController)
      }
    }

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

    Settings {
      SettingsView()
    }
  }
}
