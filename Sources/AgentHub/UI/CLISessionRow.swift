//
//  CLISessionRow.swift
//  AgentHub
//
//  Created by Assistant on 1/9/26.
//

import Foundation
import SwiftUI

// MARK: - CLISessionRow

/// Individual row for displaying a CLI session with connect action
public struct CLISessionRow: View {
  let session: CLISession
  let isMonitoring: Bool
  let onConnect: () -> Void
  let onCopyId: () -> Void
  let onOpenFile: () -> Void
  let onToggleMonitoring: () -> Void
  var showLastMessage: Bool = false

  @State private var showCopyConfirmation = false

  public init(
    session: CLISession,
    isMonitoring: Bool,
    onConnect: @escaping () -> Void,
    onCopyId: @escaping () -> Void,
    onOpenFile: @escaping () -> Void,
    onToggleMonitoring: @escaping () -> Void,
    showLastMessage: Bool = false
  ) {
    self.session = session
    self.isMonitoring = isMonitoring
    self.onConnect = onConnect
    self.onCopyId = onCopyId
    self.onOpenFile = onOpenFile
    self.onToggleMonitoring = onToggleMonitoring
    self.showLastMessage = showLastMessage
  }

  public var body: some View {
    sessionRowContent
      .padding(.vertical, 8)
      .padding(.horizontal, 10)
      .contentShape(Rectangle())
      .onTapGesture {
        onToggleMonitoring()
      }
      .agentHubRow(isHighlighted: isMonitoring)
      .help(isMonitoring ? "Stop monitoring" : "Monitor session")
  }

  // MARK: - Session Row Content

  private var sessionRowContent: some View {
    HStack(spacing: 12) {
      // Activity indicator
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)

      VStack(alignment: .leading, spacing: 4) {
        // Session ID (prominently displayed)
        sessionIdRow

        // Message preview (first or last based on toggle)
        if let message = showLastMessage ? session.lastMessage : session.firstMessage,
           !message.isEmpty {
          Text(message.prefix(80) + (message.count > 80 ? "..." : ""))
            .font(.caption)
            .foregroundColor(.primary.opacity(0.8))
            .lineLimit(1)
        }

        // Metadata row
        metadataRow
      }

      Spacer()
    }
  }

  private var statusColor: Color {
    if session.isActive {
      return .green
    }
    return isMonitoring ? .brandPrimary : .gray.opacity(0.5)
  }

  // MARK: - Session ID Row

  private var sessionIdRow: some View {
    HStack(spacing: 6) {
      if let slug = session.slug {
        // Show slug and short ID (no "Session:" label)
        Text(slug)
          .font(.system(.subheadline, design: .monospaced, weight: .semibold))
          .foregroundColor(.brandPrimary)
          .lineLimit(1)

        Text("•")
          .font(.caption)
          .foregroundColor(.secondary)

        Text(session.shortId)
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.brandPrimary)
          .fontWeight(.semibold)
      } else {
        // No slug - show "Session:" label with ID
        Text("Session: \(session.shortId)")
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.brandPrimary)
          .fontWeight(.semibold)
      }

      // Copy button with animated confirmation
      Button {
        onCopyId()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
          showCopyConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          withAnimation(.easeOut(duration: 0.2)) {
            showCopyConfirmation = false
          }
        }
      } label: {
        Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
          .font(.caption2)
          .fontWeight(showCopyConfirmation ? .bold : .regular)
          .foregroundColor(showCopyConfirmation ? .green : .secondary)
          .contentTransition(.symbolEffect(.replace))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Copy full session ID")

      // Open session file button
      Button(action: onOpenFile) {
        Image(systemName: "doc.text")
          .font(.caption2)
          .foregroundColor(.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open session file")

      // Open in external terminal button
      Button(action: onConnect) {
        Image(systemName: "rectangle.portrait.and.arrow.right")
          .font(.caption2)
          .foregroundColor(.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open in external Terminal")

      Spacer()
    }
  }

  // MARK: - Metadata Row

  private var metadataRow: some View {
    HStack(spacing: 6) {
      // Branch info
      if let branch = session.branchName {
        HStack(spacing: 2) {
          Image(systemName: session.isWorktree ? "arrow.triangle.branch" : "arrow.branch")
            .font(.caption2)
          Text(branch)
            .font(.caption)
            .lineLimit(1)
        }
        .foregroundColor(session.isWorktree ? .brandSecondary : .secondary)

        Text("\u{2022}")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      // Message count
      Text("\(session.messageCount) msgs")
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize()

      Text("\u{2022}")
        .font(.caption)
        .foregroundColor(.secondary)

      // Last activity
      Text(session.lastActivityAt.timeAgoDisplay())
        .font(.caption)
        .foregroundColor(.secondary)
        .fixedSize()
    }
    .lineLimit(1)
  }

}

// MARK: - Date Extension for Time Ago Display

extension Date {
  func timeAgoDisplay() -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: self, relativeTo: Date())
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    // Active session with first message and slug
    CLISessionRow(
      session: CLISession(
        id: "e1b8aae2-2a33-4402-a8f5-886c4d4da370",
        projectPath: "/Users/james/git/ClaudeCodeUI",
        branchName: "main",
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 42,
        isActive: true,
        firstMessage: "I want to add a feature that monitors CLI sessions",
        slug: "cryptic-orbiting-flame"
      ),
      isMonitoring: false,
      onConnect: { },
      onCopyId: { },
      onOpenFile: { },
      onToggleMonitoring: { }
    )

    // Inactive worktree session with long message (being monitored)
    CLISessionRow(
      session: CLISession(
        id: "f2c9bbf3-3b44-5513-b9f6-997d5e5eb481",
        projectPath: "/Users/james/git/ClaudeCodeUI-feature",
        branchName: "feature/sessions",
        isWorktree: true,
        lastActivityAt: Date().addingTimeInterval(-3600),
        messageCount: 15,
        isActive: false,
        firstMessage: "Help me implement a new SwiftUI view that displays session data in a hierarchical tree structure with expand/collapse functionality",
        slug: "async-coalescing-summit"
      ),
      isMonitoring: true,
      onConnect: { },
      onCopyId: { },
      onOpenFile: { },
      onToggleMonitoring: { }
    )

    // Session without slug (falls back to shortId)
    CLISessionRow(
      session: CLISession(
        id: "a3d0ccg4-4c55-6624-c0g7-aa8e6f6fc592",
        projectPath: "/Users/james/Desktop",
        branchName: nil,
        isWorktree: false,
        lastActivityAt: Date().addingTimeInterval(-86400),
        messageCount: 5,
        isActive: false,
        firstMessage: nil
      ),
      isMonitoring: false,
      onConnect: { },
      onCopyId: { },
      onOpenFile: { },
      onToggleMonitoring: { }
    )
  }
  .padding()
  .frame(width: 350)
}
