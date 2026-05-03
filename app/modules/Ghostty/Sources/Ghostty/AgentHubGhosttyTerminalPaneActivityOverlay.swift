//
//  AgentHubGhosttyTerminalPaneActivityOverlay.swift
//  AgentHub
//

import SwiftUI

struct AgentHubGhosttyTerminalPaneActivityOverlay: View {
  let activity: AgentHubGhosttyTerminalPaneActivity

  var body: some View {
    ZStack {
      Color(nsColor: .textBackgroundColor)
        .opacity(0.86)

      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)

        Text(activity.message)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(activity.message)
  }
}
