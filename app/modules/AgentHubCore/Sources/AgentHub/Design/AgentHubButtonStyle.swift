//
//  AgentHubButtonStyle.swift
//  AgentHub
//
//  Created by James Rochabrun on 3/22/26.
//

import SwiftUI

// MARK: - Outlined Button Style

struct OutlinedButtonStyle: ButtonStyle {
  var tintColor: Color = .secondary

  func makeBody(configuration: Configuration) -> some View {
    OutlinedButtonBody(
      configuration: configuration,
      tintColor: tintColor
    )
  }
}

private struct OutlinedButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let tintColor: Color

  @State private var isHovered = false

  var body: some View {
    let cornerRadius = AgentHubLayout.buttonCornerRadius
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    configuration.label
      .font(.secondaryCaption)
      .foregroundColor(tintColor)
      .padding(.horizontal, DesignTokens.Spacing.sm)
      .padding(.vertical, DesignTokens.Spacing.xs)
      .background(shape.fill(backgroundFill(isPressed: configuration.isPressed)))
      .overlay(shape.stroke(tintColor.opacity(0.4), lineWidth: 1))
      .contentShape(shape)
      .onHover { isHovered = $0 }
      .animation(.easeInOut(duration: 0.15), value: isHovered)
      .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
  }

  private func backgroundFill(isPressed: Bool) -> Color {
    if isPressed {
      return tintColor.opacity(0.15)
    } else if isHovered {
      return tintColor.opacity(0.08)
    }
    return Color.clear
  }
}

// MARK: - Dot-Syntax Access

extension ButtonStyle where Self == OutlinedButtonStyle {
  static var agentHubOutlined: OutlinedButtonStyle {
    OutlinedButtonStyle()
  }

  static func agentHubOutlined(tint: Color) -> OutlinedButtonStyle {
    OutlinedButtonStyle(tintColor: tint)
  }
}
