//
//  AgentHubApp.swift
//  AgentHub
//
//  Created by James Rochabrun on 1/11/26.
//

import SwiftUI
import AgentHubCore
import UserNotifications

// MARK: - App Delegate

/// Handles app lifecycle events for process cleanup
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  /// Shared provider instance - created here so it's available for lifecycle events
  let provider = AgentHubProvider()

  /// Update controller for Sparkle auto-updates
  let updateController = UpdateController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    // Note: We intentionally do NOT clean up orphaned processes here
    // because we can't distinguish between processes spawned by AgentHub
    // vs processes the user started directly in Terminal.app
    let webEnabled = UserDefaults.standard.object(forKey: AgentHubDefaults.webServerEnabled) as? Bool ?? false
    if webEnabled {
      Task {
        try? await provider.webServer.start()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Terminate all active terminal processes on app quit
    provider.terminateAllTerminals()
    // Stop all dev servers spawned for web preview
    DevServerManager.shared.stopAllServers()
    // Stop the embedded web terminal server
    Task {
      await provider.webServer.stop()
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    Task { @MainActor in
      NSApp.activate(ignoringOtherApps: true)
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
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
        .agentHub(appDelegate.provider)
    }
  }
}
