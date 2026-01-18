//
//  MonitoringCardView.swift
//  AgentHub
//
//  Created by Assistant on 1/11/26.
//

import SwiftUI

// MARK: - CodeChangesSheetItem

/// Identifiable wrapper for sheet(item:) pattern - captures all data needed for the sheet
private struct CodeChangesSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let codeChangesState: CodeChangesState
}

// MARK: - MonitoringCardView

/// Card view for displaying a monitored session in the monitoring panel
public struct MonitoringCardView: View {
  let session: CLISession
  let state: SessionMonitorState?
  let codeChangesState: CodeChangesState?
  let onStopMonitoring: () -> Void
  let onConnect: () -> Void
  let onCopySessionId: () -> Void
  let onOpenSessionFile: () -> Void

  @State private var codeChangesSheetItem: CodeChangesSheetItem?

  public init(
    session: CLISession,
    state: SessionMonitorState?,
    codeChangesState: CodeChangesState? = nil,
    onStopMonitoring: @escaping () -> Void,
    onConnect: @escaping () -> Void,
    onCopySessionId: @escaping () -> Void,
    onOpenSessionFile: @escaping () -> Void
  ) {
    self.session = session
    self.state = state
    self.codeChangesState = codeChangesState
    self.onStopMonitoring = onStopMonitoring
    self.onConnect = onConnect
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header with session info and actions
      header

      Divider()

      // Status row with model and path
      statusRow

      // Monitoring panel content (reuses existing component)
      SessionMonitorPanel(state: state)
    }
    .padding(12)
    .agentHubCard(isHighlighted: isHighlighted)
    .sheet(item: $codeChangesSheetItem) { item in
      CodeChangesView(
        session: item.session,
        codeChangesState: item.codeChangesState,
        onDismiss: { codeChangesSheetItem = nil }
      )
    }
  }

  private var isHighlighted: Bool {
    guard let state = state else { return false }
    switch state.status {
    case .awaitingApproval, .executingTool, .thinking:
      return true
    default:
      return false
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      // Session label + ID with adaptive layout
      ViewThatFits(in: .horizontal) {
        // Wide: show label and ID
        HStack(spacing: 4) {
          Text("Session:")
            .font(.subheadline)
            .foregroundColor(.secondary)
          Text(session.shortId)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundColor(.brandPrimary)
            .fontWeight(.semibold)
        }

        // Narrow: just ID
        Text(session.shortId)
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.brandPrimary)
          .fontWeight(.semibold)
      }

      // Copy session ID button (right after ID)
      Button(action: onCopySessionId) {
        Image(systemName: "doc.on.doc")
          .font(.caption)
          .foregroundColor(.secondary)
          .agentHubChip()
      }
      .buttonStyle(.plain)
      .help("Copy session ID")

      // View transcript button (right after copy)
      Button(action: onOpenSessionFile) {
        Image(systemName: "doc.text")
          .font(.caption)
          .foregroundColor(.secondary)
          .agentHubChip()
      }
      .buttonStyle(.plain)
      .help("View session transcript")

      Spacer()

      // Code changes button (trailing)
      if let codeChangesState, codeChangesState.changeCount > 0 {
        Button(action: {
          codeChangesSheetItem = CodeChangesSheetItem(
            session: session,
            codeChangesState: codeChangesState
          )
        }) {
          HStack(spacing: 4) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
              .font(.caption)
            Text("\(codeChangesState.changeCount)")
              .font(.system(.caption2, design: .rounded))
          }
          .foregroundColor(.brandPrimary)
          .agentHubChip()
        }
        .buttonStyle(.plain)
        .help("View code changes")
      }

      // Connect button (trailing)
      Button(action: onConnect) {
        Image(systemName: "terminal")
          .font(.caption)
          .foregroundColor(.brandPrimary)
          .agentHubChip()
      }
      .buttonStyle(.plain)
      .help("Open in Terminal")

      // Stop monitoring button (trailing)
      Button(action: onStopMonitoring) {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundColor(.secondary)
          .agentHubChip()
      }
      .buttonStyle(.plain)
      .help("Stop monitoring")
    }
  }

  // MARK: - Status Row

  private var statusRow: some View {
    ViewThatFits(in: .horizontal) {
      // Horizontal layout for wider spaces
      HStack(spacing: 6) {
        pathView
        branchPill
      }

      // Vertical layout for narrower spaces
      VStack(alignment: .leading, spacing: 4) {
        pathView
        branchPill
      }
    }
    .help(session.projectPath)
  }

  private var pathView: some View {
    HStack(spacing: 3) {
      Image(systemName: "folder")
        .font(.caption2)
        .foregroundColor(.secondary.opacity(0.6))

      Text(session.projectPath)
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var branchPill: some View {
    if let branch = session.branchName {
      Text(branch)
        .font(.caption2)
        .foregroundColor(.brandPrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          Capsule()
            .fill(Color.brandPrimary.opacity(0.12))
        )
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    // Active session
    MonitoringCardView(
      session: CLISession(
        id: "e1b8aae2-2a33-4402-a8f5-886c4d4da370",
        projectPath: "/Users/james/git/ClaudeCodeUI",
        branchName: "main",
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 42,
        isActive: true
      ),
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        currentTool: "Bash",
        lastActivityAt: Date(),
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date(), type: .toolUse(name: "Bash"), description: "swift build")
        ]
      ),
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {}
    )

    // Awaiting approval
    MonitoringCardView(
      session: CLISession(
        id: "f2c9bbf3-3b44-5513-b9f6-997d5e5eb481",
        projectPath: "/Users/james/git/MyProject",
        branchName: "feature/auth",
        isWorktree: true,
        lastActivityAt: Date(),
        messageCount: 15,
        isActive: true
      ),
      state: SessionMonitorState(
        status: .awaitingApproval(tool: "git"),
        lastActivityAt: Date(),
        model: "claude-sonnet-4-20250514",
        recentActivities: []
      ),
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {}
    )

    // Loading state
    MonitoringCardView(
      session: CLISession(
        id: "a3d0ccg4-4c55-6624-c0g7-aa8e6f6fc592",
        projectPath: "/Users/james/Desktop",
        branchName: nil,
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 5,
        isActive: false
      ),
      state: nil,
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {}
    )
  }
  .padding()
  .frame(width: 320)
}
