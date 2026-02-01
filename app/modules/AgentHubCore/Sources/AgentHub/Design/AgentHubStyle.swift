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
    // Simple black/white background based on color scheme
    let backgroundColor = colorScheme == .dark ? Color.black : Color.white

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.panelCornerRadius, style: .continuous)
          .fill(backgroundColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.panelCornerRadius, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
  }
}

private struct AgentHubCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    // Simple black/white background
    let backgroundColor = colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.98)
    let strokeColor = isHighlighted
      ? Color.brandPrimary.opacity(0.6)
      : Color.secondary.opacity(0.2)
    let strokeWidth: CGFloat = isHighlighted ? 2 : 1

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
          .fill(backgroundColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
          .stroke(strokeColor, lineWidth: strokeWidth)
      )
  }
}

private struct AgentHubRowModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isHighlighted: Bool

  func body(content: Content) -> some View {
    // Simple black/white background
    let backgroundColor = colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.96)
    let strokeColor = isHighlighted
      ? Color.brandPrimary.opacity(0.5)
      : Color.secondary.opacity(0.2)

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .fill(backgroundColor)
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
    // Simple black/white background
    let backgroundColor = colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.94)

    return content
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .fill(backgroundColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
  }
}

private struct AgentHubChipModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isActive: Bool

  func body(content: Content) -> some View {
    // Simple black/white background
    let fillColor = isActive
      ? Color.brandPrimary.opacity(0.15)
      : (colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.92))
    let strokeColor = isActive
      ? Color.brandPrimary.opacity(0.4)
      : Color.secondary.opacity(0.25)

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

private struct AgentHubFlatRowModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let isHighlighted: Bool
  let providerKind: SessionProviderKind?

  func body(content: Content) -> some View {
    // Always show subtle background, selection indicated only by left border
    let backgroundColor = colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.92)
    let accentColor: Color = if let provider = providerKind {
      Color.brandPrimary(for: provider)
    } else {
      Color.brandPrimary
    }

    return content
      .background(backgroundColor)
      .overlay(alignment: .leading) {
        // Left accent bar for highlighted state only
        if isHighlighted {
          Rectangle()
            .fill(accentColor)
            .frame(width: 2)
        }
      }
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

  func agentHubFlatRow(isHighlighted: Bool = false, providerKind: SessionProviderKind? = nil) -> some View {
    modifier(AgentHubFlatRowModifier(isHighlighted: isHighlighted, providerKind: providerKind))
  }
}
