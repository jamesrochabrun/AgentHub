//
//  GlobalStatsPopoverButton.swift
//  AgentHub
//

import SwiftUI

/// A toolbar button that shows stats in a popover
public struct GlobalStatsPopoverButton: View {
  let service: GlobalStatsService
  @State private var isShowingPopover = false

  public init(service: GlobalStatsService) {
    self.service = service
  }

  public var body: some View {
    Button(action: { isShowingPopover.toggle() }) {
      HStack(spacing: 4) {
        Image(systemName: "sparkle")
          .font(.system(size: DesignTokens.IconSize.sm))
        Text(service.formattedTotalTokens)
          .font(.caption)
          .fontWeight(.medium)
          .fontDesign(.monospaced)
          .padding(.trailing, 8)
      }
      .foregroundColor(.brandPrimary)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .help("Claude Code Stats: \(service.formattedTotalTokens) tokens")
    .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
      GlobalStatsMenuView(service: service, showQuitButton: false)
    }
  }
}
