//
//  AgentHubGhosttyTerminalTabChrome.swift
//  AgentHub
//

import SwiftUI

enum AgentHubGhosttyTerminalTabChrome {
  static let stripHeight: CGFloat = 32
  static let tabMinWidth: CGFloat = 118
  static let tabMaxWidth: CGFloat = 192
  static let firstTabCornerRadius: CGFloat = 10
  static let accent = Color.primary
  static let stripBackground = Color(nsColor: .windowBackgroundColor).opacity(0.78)
  static let activeBackground = Color(nsColor: .textBackgroundColor).opacity(0.94)
  static let hoverBackground = Color.primary.opacity(0.07)
  static let closeHoverBackground = Color.primary.opacity(0.12)
  static let divider = Color.secondary.opacity(0.18)

  static let tabEdge = Color.secondary.opacity(0.13)
}
