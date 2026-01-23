//
//  IntelligenceInputView.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import SwiftUI
import AppKit

/// A simplified text input view for the Intelligence feature.
/// Allows users to type prompts and send them to Claude Code.
struct IntelligenceInputView: View {

  // MARK: - Properties

  @Binding var viewModel: IntelligenceViewModel
  @State private var text: String = ""
  @State private var selectedModulePath: String?
  @State private var isShowingFolderPicker = false
  @FocusState private var isFocused: Bool

  /// Callback to dismiss the overlay
  var onDismiss: (() -> Void)?

  private let placeholder = "Ask Claude Code..."

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      // Header
      headerView

      Divider()

      // Module selector (when selected)
      if selectedModulePath != nil {
        moduleChipView
        Divider()
      }

      // Worktree progress (shown during orchestration)
      if let progress = viewModel.worktreeProgress {
        worktreeProgressView(progress)
      }

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
    .onChange(of: selectedModulePath) { _, newPath in
      viewModel.workingDirectory = newPath
    }
  }

  // MARK: - Header

  private var headerView: some View {
    HStack {
      Spacer()
      // Folder picker button
      Button(action: showFolderPicker) {
        Image(systemName: selectedModulePath != nil ? "folder.fill" : "folder")
          .font(.system(size: 14))
          .foregroundColor(selectedModulePath != nil ? .brandPrimary : .secondary)
      }
      .buttonStyle(.plain)
      .help("Select a module/repository")

      if viewModel.isLoading {
        ProgressView()
          .scaleEffect(0.7)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  // MARK: - Worktree Progress

  @ViewBuilder
  private func worktreeProgressView(_ progress: WorktreeCreationProgress) -> some View {
    HStack(spacing: 8) {
      ProgressView()
        .scaleEffect(0.7)

      Text(progress.statusMessage)
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)

      Spacer()

      // Show percentage if updating files
      if case .updatingFiles(let current, let total) = progress {
        Text("\(Int(Double(current) / Double(total) * 100))%")
          .font(.caption.monospacedDigit())
          .foregroundColor(.brandPrimary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color.brandPrimary.opacity(0.05))
  }

  // MARK: - Module Chip

  private var moduleChipView: some View {
    HStack(spacing: 8) {
      Image(systemName: "folder.fill")
        .font(.system(size: 12))
        .foregroundColor(.brandPrimary)

      Text(moduleName)
        .font(.system(.caption, weight: .medium))
        .foregroundColor(.primary)
        .lineLimit(1)

      Spacer()

      Button(action: { selectedModulePath = nil }) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Clear module selection")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.brandPrimary.opacity(0.1))
  }

  private var moduleName: String {
    guard let path = selectedModulePath else { return "" }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  // MARK: - Folder Picker

  private func showFolderPicker() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Select a repository or module"
    panel.prompt = "Select"

    if panel.runModal() == .OK, let url = panel.url {
      selectedModulePath = url.path
    }
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
      // Dismiss overlay on Escape
      onDismiss?()
      return .handled

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
