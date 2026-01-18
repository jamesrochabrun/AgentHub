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
  @State private var provider = AgentHubProvider()

  var body: some Scene {
    WindowGroup {
      AgentHubSessionsView()
        .agentHub(provider)
    }
    .windowStyle(.hiddenTitleBar)

    MenuBarExtra(
      isInserted: Binding(
        get: { provider.displaySettings.isMenuBarMode },
        set: { _ in }
      )
    ) {
      AgentHubMenuBarContent()
        .environment(\.agentHub, provider)
    } label: {
      AgentHubMenuBarLabel(provider: provider)
    }
    .menuBarExtraStyle(.window)
  }
}
