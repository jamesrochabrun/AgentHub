//
//  IntelligenceInputView.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import SwiftUI

/// A simplified text input view for the Intelligence feature.
/// Allows users to type prompts and send them to Claude Code.
struct IntelligenceInputView: View {

  // MARK: - Properties

  @Binding var viewModel: IntelligenceViewModel
  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  private let placeholder = "Ask Claude Code..."

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      // Header
      headerView

      Divider()

      // Input area
      VStack(alignment: .leading, spacing: 8) {
        textEditorView
        controlsRow
      }
      .padding(12)
    }
    .frame(width: 400)
    .frame(minHeight: 180)
    .background(Color(NSColor.controlBackgroundColor))
    .onAppear {
      isFocused = true
    }
  }

  // MARK: - Header

  private var headerView: some View {
    HStack {
      Image(systemName: "sparkles")
        .font(.system(size: 16))
        .foregroundColor(.brandPrimary)
      Text("Intelligence")
        .font(.headline)
        .foregroundColor(.primary)
      Spacer()
      if viewModel.isLoading {
        ProgressView()
          .scaleEffect(0.7)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  // MARK: - Text Editor

  private var textEditorView: some View {
    ZStack(alignment: .topLeading) {
      TextEditor(text: $text)
        .scrollContentBackground(.hidden)
        .focused($isFocused)
        .font(.body)
        .frame(minHeight: 60, maxHeight: 120)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .onKeyPress { key in
          handleKeyPress(key)
        }

      if text.isEmpty {
        Text(placeholder)
          .font(.body)
          .foregroundColor(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 16)
          .allowsHitTesting(false)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color(NSColor.textBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
    )
  }

  // MARK: - Controls Row

  private var controlsRow: some View {
    HStack {
      // Hint text
      Text("↵ send · ⇧↵ new line")
        .font(.caption)
        .foregroundColor(.secondary)

      Spacer()

      // Action buttons
      if viewModel.isLoading {
        cancelButton
      } else {
        sendButton
      }
    }
  }

  private var sendButton: some View {
    Button(action: sendMessage) {
      HStack(spacing: 4) {
        Text("Send")
          .font(.system(.body, weight: .medium))
        Image(systemName: "arrow.up.circle.fill")
      }
      .foregroundColor(isTextEmpty ? .secondary : .brandPrimary)
    }
    .buttonStyle(.plain)
    .disabled(isTextEmpty)
  }

  private var cancelButton: some View {
    Button(action: {
      viewModel.cancelRequest()
    }) {
      HStack(spacing: 4) {
        Text("Cancel")
          .font(.system(.body, weight: .medium))
        Image(systemName: "stop.circle.fill")
      }
      .foregroundColor(.red)
    }
    .buttonStyle(.plain)
  }

  // MARK: - Helpers

  private var isTextEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func sendMessage() {
    guard !isTextEmpty else { return }
    let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    text = ""
    viewModel.sendMessage(messageText)
  }

  private func handleKeyPress(_ key: KeyPress) -> KeyPress.Result {
    switch key.key {
    case .return:
      // Shift+Enter for new line
      if key.modifiers.contains(.shift) {
        return .ignored
      }
      // Don't send if already loading
      if viewModel.isLoading {
        return .handled
      }
      // Enter to send
      sendMessage()
      return .handled

    case .escape:
      if viewModel.isLoading {
        viewModel.cancelRequest()
        return .handled
      }
      return .ignored

    default:
      return .ignored
    }
  }
}

// MARK: - Preview

#Preview {
  @Previewable @State var viewModel = IntelligenceViewModel()

  return IntelligenceInputView(viewModel: $viewModel)
    .frame(width: 400)
}
