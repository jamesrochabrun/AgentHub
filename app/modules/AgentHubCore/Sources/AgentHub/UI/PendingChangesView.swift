//
//  PendingChangesView.swift
//  AgentHub
//
//  Created by Assistant on 1/21/26.
//

import SwiftUI
import PierreDiffsSwift
import ClaudeCodeSDK

// MARK: - PendingChangesView

/// Sheet view for displaying pending code changes before they are applied.
/// Shows a diff preview of what the Edit/Write/MultiEdit tool will do.
public struct PendingChangesView: View {
  let session: CLISession
  let pendingToolUse: PendingToolUse
  let claudeClient: (any ClaudeCode)?
  let onDismiss: () -> Void

  @State private var previewResult: PendingChangesPreviewService.PreviewResult?
  @State private var errorMessage: String?
  @State private var isLoading = true
  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap
  @State private var webViewOpacity: Double = 1.0
  @State private var isWebViewReady = false

  public init(
    session: CLISession,
    pendingToolUse: PendingToolUse,
    claudeClient: (any ClaudeCode)? = nil,
    onDismiss: @escaping () -> Void
  ) {
    self.session = session
    self.pendingToolUse = pendingToolUse
    self.claudeClient = claudeClient
    self.onDismiss = onDismiss
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
    }
    .frame(minWidth: 1000, idealWidth: 1200, maxWidth: .infinity,
           minHeight: 600, idealHeight: 800, maxHeight: .infinity)
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
    .task {
      await loadPreview()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      HStack(spacing: 8) {
        Image(systemName: "eye")
          .font(.title3)
          .foregroundColor(.orange)

        Text("Pending Changes")
          .font(.title3.weight(.semibold))

        // Tool badge
        Text(pendingToolUse.toolName)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundColor(.orange)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.orange.opacity(0.15)))
      }

      Spacer()

      // Session info
      HStack(spacing: 8) {
        Text(session.shortId)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)

        if let branch = session.branchName {
          Text("[\(branch)]")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }

      Spacer()

      Button("Close") { onDismiss() }
    }
    .padding()
    .background(Color.surfaceElevated)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if isLoading {
      loadingView
    } else if let error = errorMessage {
      errorView(error)
    } else if let preview = previewResult {
      diffView(preview)
    } else {
      Text("No preview available")
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Generating preview...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorView(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 48))
        .foregroundColor(.orange.opacity(0.5))

      Text("Could Not Generate Preview")
        .font(.headline)
        .foregroundColor(.secondary)

      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private func diffView(_ preview: PendingChangesPreviewService.PreviewResult) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // File header with controls
      fileHeader(preview)

      // Diff view
      GeometryReader { geometry in
        ZStack {
          PierreDiffView(
            oldContent: preview.currentContent,
            newContent: preview.previewContent,
            fileName: preview.fileName,
            diffStyle: $diffStyle,
            overflowMode: $overflowMode,
            onReady: {
              withAnimation(.easeInOut(duration: 0.3)) {
                isWebViewReady = true
              }
            }
          )
          .opacity(isWebViewReady ? webViewOpacity : 0)

          if !isWebViewReady {
            VStack(spacing: 12) {
              ProgressView()
                .controlSize(.small)
              Text("Loading diff...")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
          }
        }
      }
      .animation(.easeInOut(duration: 0.3), value: isWebViewReady)
    }
  }

  private func fileHeader(_ preview: PendingChangesPreviewService.PreviewResult) -> some View {
    HStack {
      // File name with icon
      HStack(spacing: 4) {
        Image(systemName: preview.isNewFile ? "doc.badge.plus" : "doc.text.fill")
          .foregroundStyle(preview.isNewFile ? .green : .blue)
        Text(preview.fileName)
          .font(.headline)
        if preview.isNewFile {
          Text("(New File)")
            .font(.caption)
            .foregroundColor(.green)
        }
      }

      Spacer()

      // Diff style toggles
      HStack(spacing: 8) {
        // Split/Unified toggle button
        Button {
          toggleDiffStyle()
        } label: {
          Image(systemName: diffStyle == .split ? "rectangle.split.2x1" : "rectangle.stack")
            .font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .help(diffStyle == .split ? "Switch to unified view" : "Switch to split view")

        // Wrap toggle button
        Button {
          toggleOverflowMode()
        } label: {
          Image(systemName: overflowMode == .wrap ? "text.alignleft" : "text.aligncenter")
            .font(.system(size: 14))
            .foregroundStyle(overflowMode == .wrap ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(overflowMode == .wrap ? "Disable word wrap" : "Enable word wrap")
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  // MARK: - Actions

  private func loadPreview() async {
    isLoading = true
    errorMessage = nil

    guard let codeChangeInput = pendingToolUse.codeChangeInput else {
      errorMessage = "No code change details available"
      isLoading = false
      return
    }

    do {
      previewResult = try await PendingChangesPreviewService.generatePreview(
        for: codeChangeInput
      )
    } catch {
      errorMessage = error.localizedDescription
    }

    isLoading = false
  }

  private func toggleDiffStyle() {
    Task {
      withAnimation(.easeOut(duration: 0.15)) {
        webViewOpacity = 0
      }
      try? await Task.sleep(for: .milliseconds(150))
      diffStyle = diffStyle == .split ? .unified : .split
      withAnimation(.easeIn(duration: 0.15)) {
        webViewOpacity = 1
      }
    }
  }

  private func toggleOverflowMode() {
    Task {
      withAnimation(.easeOut(duration: 0.15)) {
        webViewOpacity = 0
      }
      try? await Task.sleep(for: .milliseconds(150))
      overflowMode = overflowMode == .scroll ? .wrap : .scroll
      withAnimation(.easeIn(duration: 0.15)) {
        webViewOpacity = 1
      }
    }
  }
}

// MARK: - Preview

#Preview {
  PendingChangesView(
    session: CLISession(
      id: "test-session-id",
      projectPath: "/Users/test/project",
      branchName: "main",
      isWorktree: false,
      lastActivityAt: Date(),
      messageCount: 10,
      isActive: true
    ),
    pendingToolUse: PendingToolUse(
      toolName: "Edit",
      toolUseId: "test-tool-id",
      timestamp: Date(),
      input: "main.swift",
      codeChangeInput: CodeChangeInput(
        toolType: .edit,
        filePath: "/Users/test/project/src/main.swift",
        oldString: "let x = 1",
        newString: "let x = 2"
      )
    ),
    onDismiss: {}
  )
}
