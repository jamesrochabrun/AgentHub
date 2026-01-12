//
//  ContentView.swift
//  AgentHubDemo
//
//  Created by James Rochabrun on 1/11/26.
//

import SwiftUI
import AgentHub
import ClaudeCodeSDK

struct ContentView: View {
  @State private var viewModel: CLISessionsViewModel

  init() {
    let service = CLISessionMonitorService()
    // ClaudeCodeClient is the concrete implementation (ClaudeCode is a protocol)
    let claudeClient = try? ClaudeCodeClient(configuration: .default)
    _viewModel = State(initialValue: CLISessionsViewModel(
      monitorService: service,
      claudeClient: claudeClient
    ))
  }

  var body: some View {
    CLISessionsListView(viewModel: viewModel)
      .frame(minWidth: 400, minHeight: 600)
  }
}

#Preview {
  ContentView()
}
