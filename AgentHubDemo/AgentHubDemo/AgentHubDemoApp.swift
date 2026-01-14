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

  var body: some Scene {
    WindowGroup {
      ContentView()
    }

    MenuBarExtra {
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
