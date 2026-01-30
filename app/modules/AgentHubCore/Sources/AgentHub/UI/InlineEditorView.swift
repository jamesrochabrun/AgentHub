//
//  InlineEditorView.swift
//  AgentHub
//
//  Created by Assistant on 1/16/26.
//

import SwiftUI
import AppKit

/// A compact floating text editor for asking questions about specific diff lines.
/// Appears below clicked lines in the diff view.
///
/// Supports two modes:
/// - **Send immediately**: Press Enter to send the comment to Claude right away
/// - **Add to review**: Press Cmd+Enter to add the comment to the review collection
struct InlineEditorView: View {

  // MARK: - Properties

  let lineNumber: Int
  let side: String
  let fileName: String
  let errorMessage: String?

  /// Called when user presses Enter - sends immediately to Claude
  let onSubmit: (String) -> Void

  /// Called when user presses Cmd+Enter - adds to comment collection (optional)
  let onAddComment: ((String) -> Void)?

  /// Called when user wants to delete an existing comment (optional, edit mode only)
  let onDeleteComment: (() -> Void)?

  let onDismiss: () -> Void

  /// The initial text to pre-fill (for editing existing comments)
  let initialText: String

  /// Whether this is editing an existing comment
  let isEditMode: Bool

  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  private var placeholder: String {
    isEditMode ? "Update comment on line \(lineNumber)" : "Add suggestion to line \(lineNumber)"
  }

  // MARK: - Initializers

  init(
    lineNumber: Int,
    side: String,
    fileName: String,
    errorMessage: String?,
    onSubmit: @escaping (String) -> Void,
    onAddComment: ((String) -> Void)? = nil,
    onDeleteComment: (() -> Void)? = nil,
    onDismiss: @escaping () -> Void,
    initialText: String = "",
    isEditMode: Bool = false
  ) {
    self.lineNumber = lineNumber
    self.side = side
    self.fileName = fileName
    self.errorMessage = errorMessage
    self.onSubmit = onSubmit
    self.onAddComment = onAddComment
    self.onDeleteComment = onDeleteComment
    self.onDismiss = onDismiss
    self.initialText = initialText
    self.isEditMode = isEditMode
    self._text = State(initialValue: initialText)
  }

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      inputView

      // Error message
      if let error = errorMessage {
        Divider()
          .padding(.horizontal, 8)

        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundColor(.red)

          Text(error)
            .font(.system(.caption, design: .default))
            .foregroundColor(.red)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
      }
    }
    .frame(width: 700)
    .background(Color(NSColor.controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
    .onAppear {
      isFocused = true
    }
  }

  // MARK: - Input View

  private var inputView: some View {
    HStack(spacing: 8) {
      // Dismiss button
      dismissButton

      // Delete button (only in edit mode)
      if isEditMode, onDeleteComment != nil {
        deleteButton
      }

      // Text input
      textEditorView

      // Add comment button (if callback provided)
      if onAddComment != nil {
        addCommentButton
      }

      // Send button (rounded square with arrow)
      sendButton
    }
    .padding(8)
  }

  // MARK: - Text Editor

  private var textEditorView: some View {
    ZStack(alignment: .leading) {
      TextEditor(text: $text)
        .scrollContentBackground(.hidden)
        .focused($isFocused)
        .font(.system(.body, design: .default))
        .frame(minHeight: 32, maxHeight: 60)
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        .onKeyPress { key in
          handleKeyPress(key)
        }
        .padding(.top, 8)

      if text.isEmpty {
        Text(placeholder)
          .font(.body)
          .foregroundColor(.secondary)
          .padding(.leading, 11)
          .allowsHitTesting(false)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.textBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isFocused ? Color.brandPrimary.opacity(0.5) : Color(NSColor.separatorColor), lineWidth: 1)
    )
  }

  // MARK: - Dismiss Button

  private var dismissButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(width: 24, height: 24)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .help("Dismiss (Esc)")
  }

  // MARK: - Send Button

  private var sendButton: some View {
    Button(action: submitMessage) {
      Image(systemName: "arrow.up")
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(.white)
    }
    .buttonStyle(.plain)
    .frame(width: 32, height: 32)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isTextEmpty ? Color.secondary.opacity(0.3) : Color.brandPrimary)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
    .disabled(isTextEmpty)
    .help("Send to Claude (Enter)")
  }

  // MARK: - Add Comment Button

  private var addCommentButton: some View {
    Button(action: addComment) {
      Image(systemName: isEditMode ? "checkmark" : "plus")
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(isTextEmpty ? .secondary : .primary)
    }
    .buttonStyle(.plain)
    .frame(width: 32, height: 32)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isTextEmpty ? Color(NSColor.separatorColor) : Color.brandPrimary.opacity(0.5), lineWidth: 1)
    )
    .disabled(isTextEmpty)
    .help(isEditMode ? "Update comment (⌘↵)" : "Add to review (⌘↵)")
  }

  // MARK: - Delete Button

  private var deleteButton: some View {
    Button {
      onDeleteComment?()
    } label: {
      Image(systemName: "trash")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.red)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(width: 24, height: 24)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.red.opacity(0.3), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .help("Delete comment")
  }

  // MARK: - Helpers

  private var isTextEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Submits the trimmed message text via the `onSubmit` callback.
  ///
  /// Clears the text field immediately after capturing the message. This ensures
  /// the input is reset before the callback triggers view updates (e.g., dismissing
  /// the inline editor), preventing stale text from appearing if the editor is reused.
  private func submitMessage() {
    guard !isTextEmpty else { return }
    let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    text = ""
    onSubmit(messageText)
  }

  /// Adds the comment to the review collection without sending to Claude.
  private func addComment() {
    guard !isTextEmpty, let callback = onAddComment else { return }
    let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    text = ""
    callback(messageText)
  }

  /// Handles keyboard shortcuts for the inline editor.
  ///
  /// - **Enter**: Submits the message immediately to Claude
  /// - **Cmd+Enter**: Adds comment to review collection (if callback provided)
  /// - **Shift+Enter**: Inserts a new line (returns `.ignored` to allow default behavior)
  /// - **Escape**: Dismisses the editor without submitting
  private func handleKeyPress(_ key: KeyPress) -> KeyPress.Result {
    switch key.key {
    case .return:
      if key.modifiers.contains(.shift) {
        // Shift+Enter: insert newline
        return .ignored
      } else if key.modifiers.contains(.command) {
        // Cmd+Enter: add to comment collection
        addComment()
        return .handled
      }
      // Enter: submit immediately
      submitMessage()
      return .handled

    case .escape:
      onDismiss()
      return .handled

    default:
      return .ignored
    }
  }
}

// MARK: - Preview

#Preview("Default - Input Mode") {
  InlineEditorView(
    lineNumber: 42,
    side: "right",
    fileName: "Example.swift",
    errorMessage: nil,
    onSubmit: { _ in },
    onDismiss: { }
  )
  .padding(40)
  .background(Color.gray.opacity(0.2))
}

#Preview("With Add Comment") {
  InlineEditorView(
    lineNumber: 42,
    side: "right",
    fileName: "Example.swift",
    errorMessage: nil,
    onSubmit: { _ in },
    onAddComment: { _ in },
    onDismiss: { }
  )
  .padding(40)
  .background(Color.gray.opacity(0.2))
}

#Preview("Edit Mode") {
  InlineEditorView(
    lineNumber: 42,
    side: "right",
    fileName: "Example.swift",
    errorMessage: nil,
    onSubmit: { _ in },
    onAddComment: { _ in },
    onDeleteComment: { },
    onDismiss: { },
    initialText: "Consider adding error handling here",
    isEditMode: true
  )
  .padding(40)
  .background(Color.gray.opacity(0.2))
}

#Preview("With Error") {
  InlineEditorView(
    lineNumber: 42,
    side: "right",
    fileName: "Example.swift",
    errorMessage: "Failed to connect to Claude",
    onSubmit: { _ in },
    onDismiss: {}
  )
  .padding(40)
  .background(Color.gray.opacity(0.2))
}
