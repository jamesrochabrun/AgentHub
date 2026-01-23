//
//  AgentHubStyle.swift
//  AgentHub
//
//  Created by Assistant on 1/13/26.
//

import SwiftUI

public enum AgentHubLayout {
  public static let panelCornerRadius: CGFloat = 16
  public static let cardCornerRadius: CGFloat = 12
  public static let rowCornerRadius: CGFloat = 10
  public static let chipCornerRadius: CGFloat = 8
}

private struct AgentHubPanelModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.panelCornerRadius, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color.surfacePanel,
                Color.surfacePanel.opacity(colorScheme == .dark ? 0.92 : 0.98),
                Color.brandTertiary.opacity(colorScheme == .dark ? 0.06 : 0.1)
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.panelCornerRadius, style: .continuous)
          .stroke(Color.surfaceStroke.opacity(colorScheme == .dark ? 0.45 : 0.7), lineWidth: 1)
      )
  }
}

private struct AgentHubCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    let strokeColor = isHighlighted
      ? Color.brandPrimary.opacity(colorScheme == .dark ? 0.8 : 0.6)
      : Color.surfaceStroke.opacity(colorScheme == .dark ? 0.4 : 0.6)
    let strokeWidth: CGFloat = isHighlighted ? 2 : 1

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
          .fill(Color.surfaceCard)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
          .stroke(strokeColor, lineWidth: strokeWidth)
      )
      .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08), radius: 6, x: 0, y: 2)
  }
}

private struct AgentHubRowModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    // Subtle warm gray for highlight (soft dark in dark mode, warm gray in light)
    let highlightColor = Color(red: 0.55, green: 0.52, blue: 0.50)
    let highlight = isHighlighted
      ? (colorScheme == .dark ? Color.black.opacity(0.25) : highlightColor.opacity(0.08))
      : Color.clear
    let strokeColor = isHighlighted
      ? highlightColor.opacity(colorScheme == .dark ? 0.35 : 0.25)
      : Color.surfaceStroke.opacity(colorScheme == .dark ? 0.35 : 0.55)

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .fill(Color.surfacePanel.opacity(colorScheme == .dark ? 0.85 : 0.96))
          .overlay(
            RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
              .fill(highlight)
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .stroke(strokeColor, lineWidth: 1)
      )
  }
}

private struct AgentHubInsetModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .fill(Color.surfacePanel.opacity(colorScheme == .dark ? 0.8 : 0.9))
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .stroke(Color.surfaceStroke.opacity(colorScheme == .dark ? 0.3 : 0.5), lineWidth: 1)
      )
  }
}

private struct AgentHubChipModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isActive: Bool

  func body(content: Content) -> some View {
    let fillColor = isActive
      ? Color.brandPrimary.opacity(colorScheme == .dark ? 0.2 : 0.12)
      : Color.surfacePanel.opacity(colorScheme == .dark ? 0.75 : 0.9)
    let strokeColor = isActive
      ? Color.brandPrimary.opacity(colorScheme == .dark ? 0.5 : 0.35)
      : Color.surfaceStroke.opacity(colorScheme == .dark ? 0.35 : 0.55)

    return content
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous)
          .fill(fillColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous)
          .stroke(strokeColor, lineWidth: 1)
      )
  }
}

public extension View {
  func agentHubPanel() -> some View {
    modifier(AgentHubPanelModifier())
  }

  func agentHubCard(isHighlighted: Bool = false) -> some View {
    modifier(AgentHubCardModifier(isHighlighted: isHighlighted))
  }

  func agentHubRow(isHighlighted: Bool = false) -> some View {
    modifier(AgentHubRowModifier(isHighlighted: isHighlighted))
  }

  func agentHubInset() -> some View {
    modifier(AgentHubInsetModifier())
  }

  func agentHubChip(isActive: Bool = false) -> some View {
    modifier(AgentHubChipModifier(isActive: isActive))
  }
}
