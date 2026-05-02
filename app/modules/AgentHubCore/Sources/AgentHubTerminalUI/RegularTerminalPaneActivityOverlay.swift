//
//  RegularTerminalPaneActivityOverlay.swift
//  AgentHub
//

import SwiftUI

enum RegularTerminalPaneActivity: Equatable {
  case starting
  case closing

  var message: String {
    switch self {
    case .starting:
      return "Starting terminal..."
    case .closing:
      return "Closing terminal..."
    }
  }
}

struct RegularTerminalPaneActivityOverlay: View {
  let activity: RegularTerminalPaneActivity

  var body: some View {
    ZStack {
      Color(nsColor: .textBackgroundColor)
        .opacity(0.86)

      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)

        Text(activity.message)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(activity.message)
  }
}

final class RegularTerminalPaneActivityOverlayHostingView: NSHostingView<RegularTerminalPaneActivityOverlay> {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}
