//
//  MarkdownCardView.swift
//  AgentHub
//
//  Shared markdown card surface used by plan and GitHub detail views.
//

import SwiftUI

struct MarkdownCardView: View {
  let content: String
  var transparent: Bool = false

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    MarkdownView(content: content, includeScrollView: false)
      .padding(DesignTokens.Spacing.lg)
      .background(transparent ? Color.clear : cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
      .shadow(
        color: cardShadowColor,
        radius: 8,
        x: 0,
        y: 2
      )
  }

  private var cardBackground: Color {
    colorScheme == .dark ? Color(white: 0.08) : Color.white
  }

  private var cardShadowColor: Color {
    colorScheme == .dark ? Color.black.opacity(0.3) : Color.black.opacity(0.08)
  }
}
