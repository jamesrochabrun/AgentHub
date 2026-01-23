//
//  PlanView.swift
//  AgentHub
//
//  Created by Assistant on 1/20/26.
//

import ClaudeCodeSDK
import SwiftUI

// MARK: - PlanView

/// Sheet view to display plan markdown content from a session's plan file.
///
/// Shows a header with file information and session context, followed by
/// the rendered markdown content. Handles async loading and error states.
public struct PlanView: View {
  let session: CLISession
  let planState: PlanState
  let onDismiss: () -> Void

  @State private var content: String?
  @State private var isLoading = true
  @State private var errorMessage: String?

  public init(
    session: CLISession,
    planState: PlanState,
    onDismiss: @escaping () -> Void
  ) {
    self.session = session
    self.planState = planState
    self.onDismiss = onDismiss
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      header

      Divider()

      // Content
      if isLoading {
        loadingState
      } else if let error = errorMessage {
        errorState(error)
      } else if let content = content {
        markdownContent(content)
      }
    }
    .frame(
      minWidth: 700, idealWidth: 900, maxWidth: .infinity,
      minHeight: 500, idealHeight: 700, maxHeight: .infinity
    )
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
    }
    .task {
      await loadPlanContent()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      HStack(spacing: 8) {
        Image(systemName: "list.bullet.clipboard")
          .font(.title3)
          .foregroundColor(.brandPrimary)

        Text("Plan")
          .font(.title3.weight(.semibold))

        Text(planState.fileName)
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.secondary)
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

      Button("Close") {
        onDismiss()
      }
    }
    .padding()
    .background(Color.surfaceElevated)
  }

  // MARK: - Loading State

  private var loadingState: some View {
    VStack(spacing: 12) {
      ProgressView()
        .controlSize(.small)
      Text("Loading plan...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Error State

  private func errorState(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundColor(.red)

      Text("Failed to load plan")
        .font(.headline)
        .foregroundColor(.secondary)

      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  // MARK: - Markdown Content

  private func markdownContent(_ text: String) -> some View {
    MarkdownView(content: text)
  }

  // MARK: - Load Content

  private func loadPlanContent() async {
    isLoading = true
    errorMessage = nil

    do {
      // Expand tilde in path if present
      let expandedPath = (planState.filePath as NSString).expandingTildeInPath
      let fileURL = URL(fileURLWithPath: expandedPath)

      let data = try Data(contentsOf: fileURL)
      guard let text = String(data: data, encoding: .utf8) else {
        throw PlanLoadError.invalidEncoding
      }

      await MainActor.run {
        self.content = text
        self.isLoading = false
      }
    } catch {
      await MainActor.run {
        self.errorMessage = error.localizedDescription
        self.isLoading = false
      }
    }
  }
}

// MARK: - PlanLoadError

private enum PlanLoadError: LocalizedError {
  case invalidEncoding

  var errorDescription: String? {
    switch self {
    case .invalidEncoding:
      return "File content is not valid UTF-8 text"
    }
  }
}

// MARK: - Preview

#Preview {
  PlanView(
    session: CLISession(
      id: "test-session-id",
      projectPath: "/Users/test/project",
      branchName: "main",
      isWorktree: false,
      lastActivityAt: Date(),
      messageCount: 10,
      isActive: true
    ),
    planState: PlanState(filePath: "~/.claude/plans/test-plan.md"),
    onDismiss: {}
  )
}
