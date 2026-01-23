//
//  IntelligencePopoverButton.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import SwiftUI
import ClaudeCodeSDK

/// A toolbar button that toggles the Intelligence overlay.
public struct IntelligencePopoverButton: View {

  @Binding var isShowingOverlay: Bool

  public init(isShowingOverlay: Binding<Bool>) {
    _isShowingOverlay = isShowingOverlay
  }

  public var body: some View {
    Button(action: {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
        isShowingOverlay = true
      }
    }) {
      Image(systemName: "sparkles")
      .font(.system(size: DesignTokens.IconSize.md))
      .foregroundColor(.brandPrimary)
      .padding(.horizontal, 8)
      .padding(.trailing, 8)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .help("Ask Claude Code")
  }
}

// MARK: - Intelligence Overlay View

/// Full-screen overlay with transparent background and magical scale animation.
public struct IntelligenceOverlayView: View {

  @Binding var viewModel: IntelligenceViewModel
  @Binding var isPresented: Bool

  @State private var showContent = false

  public init(viewModel: Binding<IntelligenceViewModel>, isPresented: Binding<Bool>) {
    _viewModel = viewModel
    _isPresented = isPresented
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Input card at top
      IntelligenceInputView(
        viewModel: $viewModel,
        onDismiss: { dismissOverlay() }
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .shadow(color: .black.opacity(0.3), radius: 40, x: 0, y: 15)
      .scaleEffect(showContent ? 1 : 0.5)
      .opacity(showContent ? 1 : 0)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      Rectangle()
        .fill(Color.black.opacity(0.6))
        .opacity(showContent ? 1 : 0)
        .ignoresSafeArea()
        .onTapGesture {
          dismissOverlay()
        }
    )
    .onAppear {
      withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
        showContent = true
      }
    }
    .onExitCommand {
      dismissOverlay()
    }
  }

  private func dismissOverlay() {
    withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
      showContent = false
    }
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(180))
      isPresented = false
    }
  }
}

// MARK: - Preview

#Preview {
  @Previewable @State var isShowing = false
  @Previewable @State var viewModel = IntelligenceViewModel()

  return ZStack {
    IntelligencePopoverButton(isShowingOverlay: $isShowing)
      .padding()

    if isShowing {
      IntelligenceOverlayView(viewModel: $viewModel, isPresented: $isShowing)
    }
  }
  .frame(width: 600, height: 400)
}
