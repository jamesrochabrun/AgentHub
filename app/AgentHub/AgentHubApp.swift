//
//  AgentHubApp.swift
//  AgentHub
//
//  Created by James Rochabrun on 1/11/26.
//

import SwiftUI
import AgentHubCore
import Ghostty
import UserNotifications
import CoreText

// MARK: - App Delegate

/// Handles app lifecycle events for process cleanup
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  /// Shared provider instance - created here so it's available for lifecycle events.
  /// Wires the Ghostty-aware terminal surface factory; `AgentHubCore` falls back
  /// to the regular SwiftTerm surface when no provider is supplied.
  let provider = AgentHubProvider(
    terminalSurfaceFactory: DefaultEmbeddedTerminalSurfaceFactory(
      ghosttyProvider: { AgentHubGhosttyTerminalSurface() }
    )
  )

  /// Update controller for Sparkle auto-updates
  let updateController = UpdateController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    registerBundledFonts()
    // Sweep any approval hooks left installed by a previous crash/force-quit
    // before sessions start restoring. Re-installs happen naturally as each
    // session begins monitoring.
    provider.reconcileClaudeHooksOnLaunch()
    provider.cleanupOrphanedProcesses()
  }

  /// Register all bundled fonts (Geist, GeistMono, JetBrains Mono)
  private func registerBundledFonts() {
    let otfFonts = [
      "Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold",
      "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold", "GeistMono-Bold",
      "SourceCodePro-Regular"
    ]
    let ttfFonts = [
      "JetBrainsMono-Regular", "JetBrainsMono-Medium",
      "JetBrainsMono-SemiBold", "JetBrainsMono-Bold",
      "FiraCode-Regular",
      "CascadiaMono-Regular"
    ]
    for name in otfFonts {
      if let url = Bundle.main.url(forResource: name, withExtension: "otf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
    for name in ttfFonts {
      if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Terminate all active terminal processes on app quit
    provider.terminateAllTerminals()
    // Stop all dev servers spawned for web preview
    DevServerManager.shared.stopAllServers()
    // Remove every approval hook we installed and clear claims so external
    // Claude Code sessions after quit run vanilla.
    provider.flushClaudeHooksOnTerminate()
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
