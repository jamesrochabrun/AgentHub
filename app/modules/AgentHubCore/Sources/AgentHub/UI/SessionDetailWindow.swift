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
          // Note: ContextWindowBar is displayed inside SessionMonitorPanel
          SessionMonitorPanel(
            state: viewModel.monitorStates[sessionId],
            showTerminal: true,
            viewMode: .terminal,
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
    .onAppear {
      // Register detached window to hide terminal in main view
      viewModel?.registerDetachedWindow(for: sessionId)
    }
    .onDisappear {
      // Unregister detached window to restore terminal in main view
      viewModel?.unregisterDetachedWindow(for: sessionId)
    }
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
      // Session slug or short ID (prefer slug, fallback to shortId)
      if let slug = session.slug {
        Text(slug)
          .font(.system(.headline, design: .monospaced, weight: .semibold))
          .foregroundColor(.primary)
      } else {
        Text(session.shortId)
          .font(.system(.headline, design: .monospaced, weight: .semibold))
          .foregroundColor(.primary)
      }

      Spacer()

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

/// Mock preview showing the window layout with sample data
private struct SessionDetailWindowMockPreview: View {
  let colorHex: String?

  static let mockSession = CLISession(
    id: "e1b8aae2-2a33-4402-a8f5-886c4d4da370",
    projectPath: "/Users/demo/Projects/MyApp",
    branchName: "feature/new-ui",
    isWorktree: true,
    lastActivityAt: Date(),
    messageCount: 42,
    isActive: true,
    firstMessage: "Help me build a new feature",
    lastMessage: "Implementing the UI components now",
    slug: "cosmic-purple-nebula"
  )

  static let mockMonitorState = SessionMonitorState(
    status: .thinking,
    currentTool: nil,
    lastActivityAt: Date(),
    inputTokens: 45000,
    outputTokens: 1200,
    totalOutputTokens: 5600,
    model: "claude-sonnet-4-20250514",
    recentActivities: [
      ActivityEntry(
        timestamp: Date().addingTimeInterval(-30),
        type: .userMessage,
        description: "Add a color picker to the sidebar"
      ),
      ActivityEntry(
        timestamp: Date().addingTimeInterval(-20),
        type: .toolUse(name: "Read"),
        description: "CLISessionRow.swift"
      ),
      ActivityEntry(
        timestamp: Date().addingTimeInterval(-10),
        type: .toolResult(name: "Read", success: true),
        description: "Completed"
      ),
      ActivityEntry(
        timestamp: Date(),
        type: .thinking,
        description: "Analyzing the code structure..."
      )
    ]
  )

  var backgroundColor: Color {
    if let hex = colorHex {
      return Color(hex: hex).opacity(0.15)
    }
    return Color.surfaceCanvas
  }

  var body: some View {
    ZStack {
      backgroundColor
        .ignoresSafeArea()

      VStack(spacing: 0) {
        // Header
        HStack(spacing: 8) {
          // Session slug or short ID (prefer slug)
          if let slug = Self.mockSession.slug {
            Text(slug)
              .font(.system(.headline, design: .monospaced, weight: .semibold))
              .foregroundColor(.primary)
          } else {
            Text(Self.mockSession.shortId)
              .font(.system(.headline, design: .monospaced, weight: .semibold))
              .foregroundColor(.primary)
          }

          Spacer()

          // Status indicator
          Circle()
            .fill(Self.mockSession.isActive ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)

        // Monitor panel (mock - with conversation view)
        SessionMonitorPanel(
          state: Self.mockMonitorState,
          showTerminal: false,
          viewMode: .conversation,
          terminalKey: Self.mockSession.id,
          sessionId: Self.mockSession.id,
          projectPath: Self.mockSession.projectPath,
          claudeClient: nil,
          initialPrompt: nil,
          viewModel: nil,
          onPromptConsumed: nil
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
      }
    }
    .frame(minWidth: 600, minHeight: 450)
  }
}

#Preview("With Coral Color") {
  SessionDetailWindowMockPreview(colorHex: "#FF6B6B")
    .frame(width: 700, height: 500)
}

#Preview("With Blue Color") {
  SessionDetailWindowMockPreview(colorHex: "#4ECDC4")
    .frame(width: 700, height: 500)
}

#Preview("With Purple Color") {
  SessionDetailWindowMockPreview(colorHex: "#9B59B6")
    .frame(width: 700, height: 500)
}

#Preview("No Color") {
  SessionDetailWindowMockPreview(colorHex: nil)
    .frame(width: 700, height: 500)
}

#Preview("Session Not Found") {
  SessionDetailWindow(sessionId: "nonexistent-session-id")
    .agentHub()
    .frame(width: 700, height: 500)
}
