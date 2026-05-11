//
//  AgentHubGhosttyTerminalTabItem.swift
//  AgentHub
//

import SwiftUI

@MainActor
struct AgentHubGhosttyTerminalTabItem: View {
  let title: String
  let isActive: Bool
  let isFirst: Bool
  let canClose: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovered = false
  @State private var isCloseHovered = false

  var body: some View {
    HStack(spacing: 0) {
      Button(action: onSelect) {
        Text(title)
          .font(.system(size: 12, weight: isActive ? .medium : .regular))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, isFirst ? 20 : 18)
          .padding(.trailing, canClose ? 8 : 12)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if canClose {
        Button(action: onClose) {
          Label("Close Tab", systemImage: "xmark")
            .labelStyle(.iconOnly)
            .font(.system(size: 10, weight: .semibold))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!showsCloseButton)
        .foregroundStyle(Color.secondary)
        .background {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(isCloseHovered ? AgentHubGhosttyTerminalTabChrome.closeHoverBackground : Color.clear)
        }
        .opacity(closeButtonOpacity)
        .accessibilityHidden(!showsCloseButton)
        .accessibilityLabel("Close \(title) tab")
        .help("Close Tab")
        .onHover { hovering in
          isCloseHovered = hovering
        }
        .padding(.trailing, 6)
      }
    }
    .frame(
      minWidth: AgentHubGhosttyTerminalTabChrome.tabMinWidth,
      maxWidth: AgentHubGhosttyTerminalTabChrome.tabMaxWidth
    )
    .frame(height: AgentHubGhosttyTerminalTabChrome.stripHeight)
    .foregroundStyle(isActive ? Color.primary : Color.secondary)
    .background {
      tabShape.fill(tabBackground)
    }
    .overlay(alignment: .top) {
      if isActive {
        Rectangle()
          .fill(AgentHubGhosttyTerminalTabChrome.accent)
          .frame(height: 2)
          .clipShape(tabShape)
      }
    }
    .overlay(alignment: .leading) {
      if isActive {
        Rectangle()
          .fill(AgentHubGhosttyTerminalTabChrome.tabEdge)
          .frame(width: 1)
      }
    }
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(isActive ? AgentHubGhosttyTerminalTabChrome.tabEdge : AgentHubGhosttyTerminalTabChrome.divider)
        .frame(width: 1)
    }
    .clipShape(tabShape)
    .contentShape(Rectangle())
    .help(title)
    .onHover { hovering in
      isHovered = hovering
    }
    .animation(.easeOut(duration: 0.10), value: isHovered)
    .animation(.easeOut(duration: 0.10), value: isCloseHovered)
    .zIndex(isActive ? 1 : 0)
  }

  private var tabBackground: Color {
    if isActive {
      return AgentHubGhosttyTerminalTabChrome.activeBackground
    }
    return isHovered ? AgentHubGhosttyTerminalTabChrome.hoverBackground : Color.clear
  }

  private var closeButtonOpacity: Double {
    showsCloseButton ? 1 : 0
  }

  private var showsCloseButton: Bool {
    isActive || isHovered || isCloseHovered
  }

  private var tabShape: AgentHubGhosttyTerminalTabShape {
    AgentHubGhosttyTerminalTabShape(roundsTopLeading: isFirst)
  }
}
