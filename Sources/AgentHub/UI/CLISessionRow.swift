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
      .agentHubRow(isHighlighted: isMonitoring)
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

      // Monitor button
      monitorButton

      // Connect button
      connectButton
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
      // Short session ID with monospace font
      Text("Session: \(session.shortId)")
        .font(.system(.subheadline, design: .monospaced))
        .foregroundColor(.brandPrimary)
        .fontWeight(.semibold)

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
      }
      .buttonStyle(.plain)
      .help("Copy full session ID")

      // Open session file button
      Button(action: onOpenFile) {
        Image(systemName: "doc.text")
          .font(.caption2)
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Open session file")

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

  // MARK: - Monitor Button

  private var monitorButton: some View {
    Button(action: onToggleMonitoring) {
      Image(systemName: isMonitoring ? "eye.fill" : "eye")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(isMonitoring ? .brandPrimary : .secondary)
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(isMonitoring ? Color.brandPrimary.opacity(0.15) : Color.surfaceOverlay)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .stroke(isMonitoring ? Color.brandPrimary.opacity(0.4) : Color.borderSubtle, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .help(isMonitoring ? "Stop monitoring" : "Monitor session")
  }

  // MARK: - Connect Button

  private var connectButton: some View {
    Button(action: onConnect) {
      Image(systemName: "terminal")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(.secondary)
        .frame(width: 28, height: 28)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(Color.surfaceOverlay)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .help("Open in Terminal")
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
    // Active session with first message
    CLISessionRow(
      session: CLISession(
        id: "e1b8aae2-2a33-4402-a8f5-886c4d4da370",
        projectPath: "/Users/james/git/ClaudeCodeUI",
        branchName: "main",
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 42,
        isActive: true,
        firstMessage: "I want to add a feature that monitors CLI sessions"
      ),
      isMonitoring: false,
      onConnect: { print("Connect") },
      onCopyId: { print("Copy ID") },
      onOpenFile: { print("Open file") },
      onToggleMonitoring: { print("Toggle monitoring") }
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
        firstMessage: "Help me implement a new SwiftUI view that displays session data in a hierarchical tree structure with expand/collapse functionality"
      ),
      isMonitoring: true,
      onConnect: { print("Connect") },
      onCopyId: { print("Copy ID") },
      onOpenFile: { print("Open file") },
      onToggleMonitoring: { print("Toggle monitoring") }
    )

    // Session without first message
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
      onConnect: { print("Connect") },
      onCopyId: { print("Copy ID") },
      onOpenFile: { print("Open file") },
      onToggleMonitoring: { print("Toggle monitoring") }
    )
  }
  .padding()
  .frame(width: 350)
}
