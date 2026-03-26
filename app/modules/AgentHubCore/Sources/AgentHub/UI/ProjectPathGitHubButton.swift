//
//  ProjectPathGitHubButton.swift
//  AgentHub
//
//  Created by Assistant on 3/25/26.
//

import SwiftUI

struct ProjectPathGitHubButton: View {
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Text("GitHub")
        .font(.geist(size: 12, weight: .semibold))
        .underline()
        .foregroundStyle(.primary)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .shadow(color: shadowColor, radius: isHovering ? 4 : 2, y: 1)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
    }
    .help("View GitHub PRs, issues, and CI status")
    .accessibilityLabel("Open GitHub panel")
  }

  private var shadowColor: Color {
    Color.primary.opacity(isHovering ? 0.24 : 0.12)
  }
}
