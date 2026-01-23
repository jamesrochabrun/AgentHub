//
//  ContentView.swift
//  AgentHubDemo
//
//  Created by James Rochabrun on 1/11/26.
//

import SwiftUI
import AgentHubCore

/// A simple wrapper view for previewing AgentHubSessionsView.
///
/// The main application now uses `AgentHubSessionsView` directly with
/// `AgentHubProvider` for dependency injection. This ContentView is
/// kept for preview convenience only.
struct ContentView: View {
  @State private var provider = AgentHubProvider()

  var body: some View {
    AgentHubSessionsView()
      .agentHub(provider)
  }
}

#Preview {
  ContentView()
}
