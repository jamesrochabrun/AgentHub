//
//  AgentHub.swift
//  AgentHub
//
//  CLI Session Monitoring Library for Claude Code
//

import Foundation

/// AgentHub version
public let agentHubVersion = "1.0.0"

// MARK: - Quick Start
//
// AgentHub provides a simple API for monitoring Claude Code CLI sessions.
//
// ## Basic Usage (Recommended)
//
// ```swift
// import AgentHub
//
// @main
// struct MyApp: App {
//   @State private var provider = AgentHubProvider()
//
//   var body: some Scene {
//     WindowGroup {
//       AgentHubSessionsView()
//         .agentHub(provider)
//     }
//     .windowStyle(.hiddenTitleBar)
//
//     MenuBarExtra {
//       AgentHubMenuBarContent()
//         .environment(\.agentHub, provider)
//     } label: {
//       AgentHubMenuBarLabel(provider: provider)
//     }
//   }
// }
// ```
//
// ## Custom Configuration
//
// ```swift
// var config = AgentHubConfiguration.default
// config.enableDebugLogging = true
// let provider = AgentHubProvider(configuration: config)
// ```
//
// ## Direct Service Access
//
// For advanced usage, access services directly from the provider:
//
// ```swift
// let stats = provider.statsService.formattedTotalTokens
// let sessions = provider.sessionsViewModel.totalSessionCount
// ```

// MARK: - Re-exports

// Configuration types are exported via their public declarations in:
// - Configuration/AgentHubConfiguration.swift
// - Configuration/AgentHubProvider.swift
// - Configuration/AgentHubEnvironment.swift
// - Configuration/AgentHubViews.swift
// - Configuration/AgentHubDefaults.swift
