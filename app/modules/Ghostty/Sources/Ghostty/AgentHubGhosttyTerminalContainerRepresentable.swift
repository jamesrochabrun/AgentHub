//
//  AgentHubGhosttyTerminalContainerRepresentable.swift
//  AgentHub
//

import GhosttySwift
import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalContainerRepresentable: NSViewRepresentable {
  let tab: TerminalTab

  func makeNSView(context: Context) -> GhosttyTerminalContainerView {
    tab.containerView
  }

  func updateNSView(_ nsView: GhosttyTerminalContainerView, context: Context) {}
}
