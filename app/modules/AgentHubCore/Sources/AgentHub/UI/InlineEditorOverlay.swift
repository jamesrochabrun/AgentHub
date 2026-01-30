//
//  InlineEditorOverlay.swift
//  AgentHub
//
//  Created by Assistant on 1/16/26.
//

import SwiftUI

/// An overlay that positions the inline editor below clicked diff lines.
/// Handles tap-outside dismissal and edge positioning.
///
/// Supports both immediate submission and adding comments to a review collection.
struct InlineEditorOverlay: View {

  // MARK: - Properties

  @Bindable var state: InlineEditorState
  let containerSize: CGSize

  /// Called when user presses Enter - sends immediately to Claude
  let onSubmit: (String, Int, String, String) -> Void

  /// Called when user presses Cmd+Enter - adds to comment collection (optional)
  let onAddComment: ((String, Int, String, String, String) -> Void)?

  /// Comments state for checking existing comments (optional)
  let commentsState: DiffCommentsState?

  // Editor dimensions for positioning calculations
  private let editorWidth: CGFloat = 700
  private let editorHeight: CGFloat = 64
  private let verticalOffset: CGFloat = 12
  private let leadingPadding: CGFloat = 20

  // MARK: - Initializer

  /// Creates an inline editor overlay for diff line interactions.
  ///
  /// - Parameters:
  ///   - state: The shared state controlling editor visibility and position.
  ///   - containerSize: The size of the container view for position calculations.
  ///   - onSubmit: Called when user presses Enter to send immediately to Claude.
  ///     Parameters: (message, lineNumber, side, fileName)
  ///   - onAddComment: Called when user presses Cmd+Enter to add to review collection.
  ///     Parameters: (message, lineNumber, side, fileName, lineContent). Optional.
  ///   - commentsState: State manager for existing comments, used for edit mode detection. Optional.
  init(
    state: InlineEditorState,
    containerSize: CGSize,
    onSubmit: @escaping (String, Int, String, String) -> Void,
    onAddComment: ((String, Int, String, String, String) -> Void)? = nil,
    commentsState: DiffCommentsState? = nil
  ) {
    self.state = state
    self.containerSize = containerSize
    self.onSubmit = onSubmit
    self.onAddComment = onAddComment
    self.commentsState = commentsState
  }

  // MARK: - Computed Properties

  /// Check if there's an existing comment at the current location
  private var existingComment: DiffComment? {
    commentsState?.getComment(
      filePath: state.fileName,
      lineNumber: state.lineNumber,
      side: state.side
    )
  }

  /// Whether we're in edit mode (editing an existing comment)
  private var isEditMode: Bool {
    existingComment != nil
  }

  /// The initial text to show (from existing comment or empty)
  private var initialText: String {
    existingComment?.text ?? ""
  }

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
          onAddComment: onAddComment != nil ? { message in
            // Add to comment collection
            onAddComment?(
              message,
              state.lineNumber,
              state.side,
              state.fileName,
              state.lineContent ?? ""
            )
            withAnimation(.easeOut(duration: 0.15)) {
              state.dismiss()
            }
          } : nil,
          onDeleteComment: isEditMode ? {
            // Delete existing comment
            if let comment = existingComment {
              commentsState?.removeComment(id: comment.id)
            }
            withAnimation(.easeOut(duration: 0.15)) {
              state.dismiss()
            }
          } : nil,
          onDismiss: {
            withAnimation(.easeOut(duration: 0.15)) {
              state.dismiss()
            }
          },
          initialText: initialText,
          isEditMode: isEditMode
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
          onSubmit: { _, _, _, _ in }
        )
      }
      .frame(width: 600, height: 600)
    }
  }

  return PreviewWrapper()
}
