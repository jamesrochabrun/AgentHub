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
struct InlineEditorView: View {

  // MARK: - Properties

  let lineNumber: Int
  let side: String
  let fileName: String
  let errorMessage: String?
  let onSubmit: (String) -> Void
  let onDismiss: () -> Void

  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  private var placeholder: String { "Add suggestion to line \(lineNumber)" }

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

      // Text input
      textEditorView

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

      if text.isEmpty {
        Text(placeholder)
          .font(.body)
          .foregroundColor(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 14)
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
    .help("Send (Enter)")
  }

  // MARK: - Helpers

  private var isTextEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submitMessage() {
    guard !isTextEmpty else { return }
    let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    onSubmit(messageText)
  }

  private func handleKeyPress(_ key: KeyPress) -> KeyPress.Result {
    switch key.key {
    case .return:
      // Shift+Enter for new line
      if key.modifiers.contains(.shift) {
        return .ignored
      }
      // Enter to send
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
    onSubmit: { message in
      print("Submitted: \(message)")
    },
    onDismiss: {
      print("Dismissed")
    }
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
