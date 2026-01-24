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

      VStack(spacing: 16) {
        if let session = findSession() {
          sessionInfoView(session: session)
        } else {
          noSessionView
        }
      }
      .padding(24)
    }
    .frame(minWidth: 400, minHeight: 300)
  }

  // MARK: - Background Color

  private var backgroundColor: Color {
    guard let colorHex = viewModel?.getSessionColor(for: sessionId) else {
      // Default subtle background if no color assigned
      return Color.surfaceCanvas
    }
    return Color(hex: colorHex).opacity(0.15)
  }

  // MARK: - Session Info View

  @ViewBuilder
  private func sessionInfoView(session: CLISession) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      // Header with session identifier
      HStack {
        if let slug = session.slug {
          Text(slug)
            .font(.system(.title2, design: .monospaced, weight: .semibold))
            .foregroundColor(.primary)
        }

        Text(session.shortId)
          .font(.system(.title3, design: .monospaced))
          .foregroundColor(.secondary)

        Spacer()

        // Color indicator if assigned
        if let colorHex = viewModel?.getSessionColor(for: sessionId) {
          Circle()
            .fill(Color(hex: colorHex))
            .frame(width: 12, height: 12)
        }
      }

      Divider()

      // Project path
      VStack(alignment: .leading, spacing: 4) {
        Text("Project")
          .font(.caption)
          .foregroundColor(.secondary)
        Text(session.projectPath)
          .font(.system(.body, design: .monospaced))
          .foregroundColor(.primary)
          .lineLimit(2)
      }

      // Branch info
      if let branch = session.branchName {
        VStack(alignment: .leading, spacing: 4) {
          Text("Branch")
            .font(.caption)
            .foregroundColor(.secondary)
          HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
              .font(.body)
            Text(branch)
              .font(.system(.body, design: .monospaced))
          }
          .foregroundColor(session.isWorktree ? .brandSecondary : .primary)
        }
      }

      // Status
      HStack(spacing: 8) {
        Circle()
          .fill(session.isActive ? Color.green : Color.gray.opacity(0.5))
          .frame(width: 8, height: 8)
        Text(session.isActive ? "Active" : "Inactive")
          .font(.body)
          .foregroundColor(.secondary)

        Spacer()

        Text("\(session.messageCount) messages")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
}
