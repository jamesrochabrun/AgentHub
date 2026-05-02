//
//  TerminalPanelActivityBanner.swift
//  AgentHub
//

import SwiftUI

struct TerminalPanelActivityBanner: View {
  let message: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)

      Text(message)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
    }
    .foregroundStyle(.primary)
    .padding(.horizontal, 11)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay {
      Capsule()
        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(message)
  }
}
