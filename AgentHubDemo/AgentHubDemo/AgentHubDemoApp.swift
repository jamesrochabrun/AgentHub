//
//  AgentHubDemoApp.swift
//  AgentHubDemo
//
//  Created by James Rochabrun on 1/11/26.
//

import SwiftUI
import AgentHub

@main
struct AgentHubDemoApp: App {
  @State private var statsService = GlobalStatsService()
  @State private var displaySettings = StatsDisplaySettings(.menuBar)

  var body: some Scene {
    WindowGroup {
      ContentView(
        statsService: statsService,
        displaySettings: displaySettings
      )
    }
    .windowStyle(.hiddenTitleBar)

    MenuBarExtra(
      isInserted: Binding(
        get: { displaySettings.isMenuBarMode },
        set: { _ in }
      )
    ) {
      GlobalStatsMenuView(service: statsService)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "sparkle")
        Text(statsService.formattedTotalTokens)
      }
    }
    .menuBarExtraStyle(.window)
  }
}
