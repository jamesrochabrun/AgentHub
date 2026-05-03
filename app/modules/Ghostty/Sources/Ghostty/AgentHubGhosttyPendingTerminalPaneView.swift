//
//  AgentHubGhosttyPendingTerminalPaneView.swift
//  AgentHub
//

import SwiftUI

@MainActor
struct AgentHubGhosttyPendingTerminalPaneView: View {
  let activity: AgentHubGhosttyTerminalPaneActivity

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Text("Shell")
          .font(.caption2.weight(.medium))
          .lineLimit(1)
          .frame(minWidth: 76, maxWidth: 150, alignment: .leading)
          .frame(height: 28)
          .padding(.leading, 10)
          .padding(.trailing, 10)
          .foregroundStyle(Color.primary)
          .background(Color.primary.opacity(0.12))
          .overlay(alignment: .trailing) {
            Rectangle()
              .fill(Color.primary.opacity(0.14))
              .frame(width: 1)
          }
          .overlay(alignment: .bottom) {
            Rectangle()
              .fill(Color.accentColor.opacity(0.75))
              .frame(height: 2)
          }

        Spacer(minLength: 0)
      }
      .frame(height: 28)
      .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color.secondary.opacity(0.18))
          .frame(height: 1)
      }

      AgentHubGhosttyTerminalPaneActivityOverlay(activity: activity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }
}
