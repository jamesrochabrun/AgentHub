//
//  InlineEditorOverlay.swift
//  AgentHub
//
//  Created by Assistant on 1/16/26.
//

import SwiftUI

/// An overlay that positions the inline editor below clicked diff lines.
/// Handles tap-outside dismissal and edge positioning.
struct InlineEditorOverlay: View {

  // MARK: - Properties

  @Bindable var state: InlineEditorState
  let containerSize: CGSize
  let onSubmit: (String, Int, String, String) -> Void

  // Editor dimensions for positioning calculations
  private let editorWidth: CGFloat = 700
  private let editorHeight: CGFloat = 64
  private let verticalOffset: CGFloat = 12
  private let leadingPadding: CGFloat = 20

  // MARK: - Body

  var body: some View {
    ZStack {
      // Allow taps to pass through to underlying diff view
      // This enables clicking another line to immediately switch to it
      // Dismiss via Escape key or by clicking a new line
      Color.clear
        .allowsHitTesting(false)

      // Positioned editor
      if state.isShowing {
        let position = calculatePosition()

        InlineEditorView(
          lineNumber: state.lineNumber,
          side: state.side,
          fileName: state.fileName,
          errorMessage: state.errorMessage,
          onSubmit: { message in
            // Submit will open Terminal with resumed session
            onSubmit(message, state.lineNumber, state.side, state.fileName)
          },
          onDismiss: {
            withAnimation(.easeOut(duration: 0.15)) {
              state.dismiss()
            }
          }
        )
        .position(position)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
      }
    }
    .animation(.easeOut(duration: 0.2), value: state.isShowing)
  }

  // MARK: - Position Calculation

  /// Calculates the best position for the editor based on anchor point and container bounds
  private func calculatePosition() -> CGPoint {
    // anchorPoint is the mouse click position in SwiftUI coordinates (origin top-left)
    let anchorY = state.anchorPoint.y
    print("[InlineEditorOverlay] anchorPoint: \(state.anchorPoint), containerSize: \(containerSize)")

    // Calculate X position (leading-aligned)
    let halfWidth = editorWidth / 2
    var x = leadingPadding + halfWidth  // Position at leading edge

    // Keep within horizontal bounds (ensure right edge doesn't overflow)
    let maxX = containerSize.width - halfWidth - 10
    x = min(x, maxX)

    // Calculate Y position (prefer below the line, but flip above if near bottom)
    // .position() places center of view, so add half the editor height
    var y = anchorY + verticalOffset + (editorHeight / 2)

    // Check if editor would go off bottom
    let bottomEdge = y + (editorHeight / 2)
    if bottomEdge > containerSize.height - 20 {
      // Position above the anchor point instead (subtract line height estimate)
      y = anchorY - 20 - verticalOffset - (editorHeight / 2)
    }

    // Ensure not off top
    let topEdge = y - (editorHeight / 2)
    if topEdge < 10 {
      y = 10 + (editorHeight / 2)
    }

    return CGPoint(x: x, y: y)
  }
}

// MARK: - Preview

#Preview {
  struct PreviewWrapper: View {
    @State var state = InlineEditorState()

    var body: some View {
      ZStack {
        Color.gray.opacity(0.3)

        VStack {
          Button("Show at top") {
            state.show(at: CGPoint(x: 300, y: 100), lineNumber: 10, side: "left", fileName: "Test.swift")
          }
          Button("Show at center") {
            state.show(at: CGPoint(x: 300, y: 300), lineNumber: 42, side: "right", fileName: "Test.swift")
          }
          Button("Show at bottom") {
            state.show(at: CGPoint(x: 300, y: 550), lineNumber: 99, side: "unified", fileName: "Test.swift")
          }
        }

        InlineEditorOverlay(
          state: state,
          containerSize: CGSize(width: 600, height: 600),
          onSubmit: { message, line, side, file in
            print("Line \(line) (\(side)) in \(file): \(message)")
          }
        )
      }
      .frame(width: 600, height: 600)
    }
  }

  return PreviewWrapper()
}
