//
//  SessionDetailWindow.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import SwiftUI

// MARK: - SessionDetailWindow

/// A detached window view for displaying a single session with its assigned color as background.
/// Used with WindowGroup(for: String.self) where the String is the session ID.
/// Shows SessionMonitorPanel with terminal view for the session.
public struct SessionDetailWindow: View {
  /// The session ID to display
  let sessionId: String

  /// Access to the sessions view model directly for proper @Observable tracking
  /// This ensures color changes trigger re-renders in real-time
  @Environment(CLISessionsViewModel.self) private var viewModel: CLISessionsViewModel?

  public init(sessionId: String) {
    self.sessionId = sessionId
  }

  public var body: some View {
    ZStack {
      // Background color based on session's assigned color
      backgroundColor
        .ignoresSafeArea()

      VStack(spacing: 0) {
        if let session = findSession(), let viewModel = viewModel {
          // Header with session identifier
          sessionHeader(session: session)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

          // SessionMonitorPanel with terminal view
          SessionMonitorPanel(
            state: viewModel.monitorStates[sessionId],
            showTerminal: true,
            terminalKey: sessionId,
            sessionId: sessionId,
            projectPath: session.projectPath,
            claudeClient: viewModel.claudeClient,
            initialPrompt: nil,
            viewModel: viewModel,
            onPromptConsumed: nil
          )
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
        } else {
          noSessionView
            .padding(24)
        }
      }
    }
    .frame(minWidth: 600, minHeight: 450)
  }

  // MARK: - Background Color

  private var backgroundColor: Color {
    guard let colorHex = viewModel?.getSessionColor(for: sessionId) else {
      // Default subtle background if no color assigned
      return Color.surfaceCanvas
    }
    return Color(hex: colorHex).opacity(0.15)
  }

  // MARK: - Session Header

  @ViewBuilder
  private func sessionHeader(session: CLISession) -> some View {
    HStack(spacing: 8) {
      // Color indicator if assigned
      if let colorHex = viewModel?.getSessionColor(for: sessionId) {
        Circle()
          .fill(Color(hex: colorHex))
          .frame(width: 10, height: 10)
      }

      // Session slug or short ID
      if let slug = session.slug {
        Text(slug)
          .font(.system(.headline, design: .monospaced, weight: .semibold))
          .foregroundColor(.primary)
      }

      Text(session.shortId)
        .font(.system(.subheadline, design: .monospaced))
        .foregroundColor(.secondary)

      Spacer()

      // Branch info (compact)
      if let branch = session.branchName {
        HStack(spacing: 4) {
          Image(systemName: "arrow.triangle.branch")
            .font(.caption)
          Text(branch)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
        }
        .foregroundColor(session.isWorktree ? .brandSecondary : .secondary)
      }

      // Status indicator
      Circle()
        .fill(session.isActive ? Color.green : Color.gray.opacity(0.5))
        .frame(width: 8, height: 8)
    }
  }

  // MARK: - No Session View

  private var noSessionView: some View {
    VStack(spacing: 12) {
      Image(systemName: "questionmark.circle")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("Session Not Found")
        .font(.headline)
        .foregroundColor(.primary)
      Text("ID: \(sessionId.prefix(8))...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Helpers

  private func findSession() -> CLISession? {
    viewModel?.findSession(byId: sessionId)
  }
}

// MARK: - Preview

#Preview {
  SessionDetailWindow(sessionId: "e1b8aae2-2a33-4402-a8f5-886c4d4da370")
    .agentHub()
    .frame(width: 700, height: 500)
}
