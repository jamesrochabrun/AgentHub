//
//  AgentHubGhosttyPendingTerminalPaneView.swift
//  AgentHub
//

import SwiftUI

@MainActor
struct AgentHubGhosttyPendingTerminalPaneView: View {
  let activity: AgentHubGhosttyTerminalPaneActivity
  let chromeStyle: AgentHubGhosttyTerminalTabChrome.Style

  var body: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .bottom) {
        chromeStyle.stripBackgroundColor

        Rectangle()
          .fill(chromeStyle.dividerColor)
          .frame(height: 1)

        HStack(spacing: 0) {
          AgentHubGhosttyTerminalTabItem(
            title: "Shell",
            isActive: true,
            isFirst: true,
            canClose: false,
            chromeStyle: chromeStyle,
            onSelect: {},
            onClose: {}
          )

          Spacer(minLength: 0)
        }
      }
      .frame(height: AgentHubGhosttyTerminalTabChrome.stripHeight)

      AgentHubGhosttyTerminalPaneActivityOverlay(activity: activity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }
}
