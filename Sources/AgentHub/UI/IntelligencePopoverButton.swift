//
//  IntelligencePopoverButton.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import SwiftUI
import ClaudeCodeSDK

/// A toolbar button that opens the Intelligence popover for AI interactions.
public struct IntelligencePopoverButton: View {

  @State private var isShowingPopover = false
  @State private var viewModel: IntelligenceViewModel

  /// Creates an Intelligence popover button
  /// - Parameter claudeClient: Optional Claude Code client. If not provided, creates a default one.
  public init(claudeClient: ClaudeCode? = nil) {
    _viewModel = State(initialValue: IntelligenceViewModel(claudeClient: claudeClient))
  }

  public var body: some View {
    Button(action: { isShowingPopover.toggle() }) {
      HStack(spacing: 4) {
        Image(systemName: "sparkles")
          .font(.system(size: DesignTokens.IconSize.md))
        Text("Ask")
          .font(.caption)
          .fontWeight(.medium)
      }
      .foregroundColor(.brandPrimary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .help("Ask Claude Code")
    .popover(isPresented: $isShowingPopover, arrowEdge: .bottom) {
      IntelligenceInputView(viewModel: $viewModel)
    }
  }
}

// MARK: - Preview

#Preview {
  IntelligencePopoverButton()
    .padding()
}
