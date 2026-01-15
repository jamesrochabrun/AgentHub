//
//  ContentView.swift
//  AgentHubDemo
//
//  Created by James Rochabrun on 1/11/26.
//

import SwiftUI
import AgentHub
import ClaudeCodeSDK

/// The main content view for the AgentHubDemo application.
///
/// This view serves as the root of the application's view hierarchy, initializing
/// the required services and displaying the CLI sessions list interface.
///
/// ## Overview
/// `ContentView` sets up the dependency graph for the application by:
/// - Creating a `CLISessionMonitorService` to track active CLI sessions
/// - Initializing a `ClaudeCodeClient` for AI-powered interactions
/// - Injecting these dependencies into a `CLISessionsViewModel`
///
/// ## Example
/// ```swift
/// @main
/// struct AgentHubDemoApp: App {
///   var body: some Scene {
///     WindowGroup {
///       ContentView()
///     }
///   }
/// }
/// ```
struct ContentView: View {

  /// The view model managing CLI session state and business logic.
  @State private var viewModel: CLISessionsViewModel

  /// Optional stats service for popover mode display
  var statsService: GlobalStatsService?

  /// Optional display settings for controlling stats display mode
  var displaySettings: StatsDisplaySettings?

  /// Creates a new content view with all required dependencies.
  ///
  /// Initializes the monitoring service and Claude client, then constructs
  /// the view model with these dependencies. If the Claude client fails to
  /// initialize, the view model will receive `nil` and should handle this
  /// gracefully.
  ///
  /// - Parameters:
  ///   - statsService: Optional stats service for popover mode
  ///   - displaySettings: Optional settings controlling stats display mode
  init(
    statsService: GlobalStatsService? = nil,
    displaySettings: StatsDisplaySettings? = nil
  ) {
    let service = CLISessionMonitorService()
    let claudeClient = try? ClaudeCodeClient(configuration: .default)
    _viewModel = State(initialValue: CLISessionsViewModel(
      monitorService: service,
      claudeClient: claudeClient
    ))
    self.statsService = statsService
    self.displaySettings = displaySettings
  }

  var body: some View {
    CLISessionsListView(viewModel: viewModel)
      .frame(minWidth: 400, minHeight: 600)
      .toolbar(removing: .title)
      .toolbar {
        ToolbarItem(placement: .principal) {
          HStack {
            Spacer()
            if let settings = displaySettings,
               settings.isPopoverMode,
               let service = statsService {
              GlobalStatsPopoverButton(service: service)
            }
          }
          .frame(maxWidth: .infinity)
        }
      }
  }
}

#Preview {
  ContentView()
}
