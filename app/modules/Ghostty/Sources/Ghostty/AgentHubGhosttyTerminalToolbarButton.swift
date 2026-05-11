//
//  AgentHubGhosttyTerminalToolbarButton.swift
//  AgentHub
//

import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalToolbarButton: View {
  let title: String
  let systemImage: String
  let help: String
  let isDisabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  init(
    title: String,
    systemImage: String,
    help: String,
    isDisabled: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.help = help
    self.isDisabled = isDisabled
    self.action = action
  }

  var body: some View {
    Button(title, systemImage: systemImage, action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(isDisabled ? Color.secondary.opacity(0.45) : Color.secondary)
      .frame(width: 28, height: 28)
      .background {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(isHovered && !isDisabled ? AgentHubGhosttyTerminalTabChrome.hoverBackground : Color.clear)
      }
      .contentShape(Rectangle())
      .disabled(isDisabled)
      .accessibilityLabel(title)
      .help(help)
      .onHover { hovering in
        isHovered = hovering
      }
      .animation(.easeOut(duration: 0.10), value: isHovered)
  }
}
