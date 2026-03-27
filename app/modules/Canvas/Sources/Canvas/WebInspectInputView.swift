//
//  WebInspectInputView.swift
//  WebInspector
//
//  Floating input overlay that appears after the user clicks an element
//  in web inspect mode. Shows element context and accepts an instruction.
//

import AppKit
import SwiftUI

/// Compact floating editor shown at the bottom of the web preview after an element is selected.
///
/// Displays a compact element summary and a text field for the user to describe the change
/// they want. Enter submits; Escape dismisses.
public struct WebInspectInputView: View {

  // MARK: Lifecycle

  public init(
    element: ElementInspectorData,
    onSubmit: @escaping (String) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.element = element
    self.onSubmit = onSubmit
    self.onDismiss = onDismiss
  }

  // MARK: Internal

  let element: ElementInspectorData
  let onSubmit: (String) -> Void
  let onDismiss: () -> Void

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      elementSummary

      Divider()

      inputRow
    }
    .frame(maxWidth: .infinity)
    .background(Color(NSColor.controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: -4)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
    .onAppear {
      isFocused = true
    }
  }

  // MARK: Private

  @State private var text = ""
  @FocusState private var isFocused: Bool

  private var elementSummary: some View {
    HStack(spacing: 6) {
      // Tag badge
      Text(element.tagName.lowercased())
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.blue.opacity(0.8))
        )

      // Selector
      Text(element.cssSelector)
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer()

      // Text preview (if any)
      if !element.textContent.isEmpty {
        Text("\"\(element.textContent)\"")
          .font(.system(size: 11))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: 140)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
  }

  private var inputRow: some View {
    HStack(spacing: 8) {
      dismissButton
      textEditorView
      sendButton
    }
    .padding(8)
  }

  private var textEditorView: some View {
    TextField("Describe the change...", text: $text, axis: .vertical)
      .textFieldStyle(.plain)
      .focused($isFocused)
      .font(.system(size: 13))
      .lineLimit(1...3)
      .padding(.horizontal, 11)
      .padding(.vertical, 10)
      .onKeyPress { key in
        handleKeyPress(key)
      }
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.textBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          isFocused ? Color.accentColor.opacity(0.5) : Color(NSColor.separatorColor),
          lineWidth: 1
        )
    )
  }

  private var dismissButton: some View {
    Button(action: onDismiss) {
      Image(systemName: "xmark")
        .font(.system(size: 12))
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

  private var sendButton: some View {
    Button(action: submitMessage) {
      Image(systemName: "arrow.up")
        .font(.system(size: 14))
        .foregroundColor(.white)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(width: 32, height: 32)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isTextEmpty ? Color.secondary.opacity(0.3) : Color.accentColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
    .contentShape(Rectangle())
    .disabled(isTextEmpty)
    .help("Send to Claude (Enter)")
  }

  private var isTextEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submitMessage() {
    guard !isTextEmpty else { return }
    let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
    text = ""
    onSubmit(instruction)
  }

  private func handleKeyPress(_ key: KeyPress) -> KeyPress.Result {
    switch key.key {
    case .return:
      if key.modifiers.contains(.shift) {
        return .ignored
      }
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

#Preview {
  WebInspectInputView(
    element: ElementInspectorData(
      id: UUID(),
      tagName: "BUTTON",
      elementId: "",
      className: "primary-btn submit-btn",
      textContent: "Submit",
      outerHTML: "<button class=\"primary-btn submit-btn\">Submit</button>",
      cssSelector: ".form-container > .actions > button.primary-btn",
      computedStyles: [
        "background-color": "#FF385C",
        "color": "#fff",
        "font-size": "16px",
        "padding": "12px 24px",
      ],
      boundingRect: CGRect(x: 100, y: 200, width: 120, height: 44)
    ),
    onSubmit: { _ in },
    onDismiss: {}
  )
  .padding(40)
  .background(Color.gray.opacity(0.2))
}
