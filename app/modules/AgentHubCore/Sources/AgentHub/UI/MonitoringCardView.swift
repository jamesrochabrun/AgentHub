//
//  MonitoringCardView.swift
//  AgentHub
//
//  Created by Assistant on 1/11/26.
//

import ClaudeCodeSDK
import SwiftUI

// MARK: - CodeChangesSheetItem

/// Identifiable wrapper for sheet(item:) pattern - captures all data needed for the sheet
private struct CodeChangesSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let codeChangesState: CodeChangesState
}

// MARK: - GitDiffSheetItem

/// Identifiable wrapper for git diff sheet - captures session and project path
private struct GitDiffSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let projectPath: String
}

// MARK: - PlanSheetItem

/// Identifiable wrapper for plan sheet - captures session and plan state
private struct PlanSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let planState: PlanState
}

// MARK: - PendingChangesSheetItem

/// Identifiable wrapper for pending changes preview sheet
private struct PendingChangesSheetItem: Identifiable {
  let id = UUID()
  let session: CLISession
  let pendingToolUse: PendingToolUse
}

// MARK: - MonitoringCardView

/// Card view for displaying a monitored session in the monitoring panel
public struct MonitoringCardView: View {
  let session: CLISession
  let state: SessionMonitorState?
  let codeChangesState: CodeChangesState?
  let planState: PlanState?
  let claudeClient: (any ClaudeCode)?
  let showTerminal: Bool
  let initialPrompt: String?
  let terminalKey: String?  // Key for terminal storage (session ID or "pending-{pendingId}")
  let viewModel: CLISessionsViewModel?
  let onToggleTerminal: (Bool) -> Void
  let onStopMonitoring: () -> Void
  let onConnect: () -> Void
  let onCopySessionId: () -> Void
  let onOpenSessionFile: () -> Void
  let onRefreshTerminal: () -> Void
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?
  let onPromptConsumed: (() -> Void)?

  @State private var codeChangesSheetItem: CodeChangesSheetItem?
  @State private var gitDiffSheetItem: GitDiffSheetItem?
  @State private var planSheetItem: PlanSheetItem?
  @State private var pendingChangesSheetItem: PendingChangesSheetItem?
  @Environment(\.colorScheme) private var colorScheme

  public init(
    session: CLISession,
    state: SessionMonitorState?,
    codeChangesState: CodeChangesState? = nil,
    planState: PlanState? = nil,
    claudeClient: (any ClaudeCode)? = nil,
    showTerminal: Bool = false,
    initialPrompt: String? = nil,
    terminalKey: String? = nil,
    viewModel: CLISessionsViewModel? = nil,
    onToggleTerminal: @escaping (Bool) -> Void,
    onStopMonitoring: @escaping () -> Void,
    onConnect: @escaping () -> Void,
    onCopySessionId: @escaping () -> Void,
    onOpenSessionFile: @escaping () -> Void,
    onRefreshTerminal: @escaping () -> Void,
    onInlineRequestSubmit: ((String, CLISession) -> Void)? = nil,
    onPromptConsumed: (() -> Void)? = nil
  ) {
    self.session = session
    self.state = state
    self.codeChangesState = codeChangesState
    self.planState = planState
    self.claudeClient = claudeClient
    self.showTerminal = showTerminal
    self.initialPrompt = initialPrompt
    self.terminalKey = terminalKey
    self.viewModel = viewModel
    self.onToggleTerminal = onToggleTerminal
    self.onStopMonitoring = onStopMonitoring
    self.onConnect = onConnect
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
    self.onRefreshTerminal = onRefreshTerminal
    self.onInlineRequestSubmit = onInlineRequestSubmit
    self.onPromptConsumed = onPromptConsumed
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with session info and actions
      header
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      Divider()

      // Path row with folder, branch, and diff button
      pathRow
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

      // Context bar (if available)
      if let state = state, state.inputTokens > 0 {
        Divider()

        ContextWindowBar(
          percentage: state.contextWindowUsagePercentage,
          formattedUsage: state.formattedContextUsage,
          model: state.model
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }

      // Recent activity (with status) or terminal
      Divider()

      monitorContent
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    .background(colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.92))
    .sheet(item: $codeChangesSheetItem) { item in
      CodeChangesView(
        session: item.session,
        codeChangesState: item.codeChangesState,
        onDismiss: { codeChangesSheetItem = nil },
        claudeClient: claudeClient
      )
    }
    .sheet(item: $gitDiffSheetItem) { item in
      GitDiffView(
        session: item.session,
        projectPath: item.projectPath,
        onDismiss: { gitDiffSheetItem = nil },
        claudeClient: claudeClient,
        onInlineRequestSubmit: onInlineRequestSubmit
      )
    }
    .sheet(item: $planSheetItem) { item in
      PlanView(
        session: item.session,
        planState: item.planState,
        onDismiss: { planSheetItem = nil }
      )
    }
    .sheet(item: $pendingChangesSheetItem) { item in
      PendingChangesView(
        session: item.session,
        pendingToolUse: item.pendingToolUse,
        claudeClient: claudeClient,
        onDismiss: { pendingChangesSheetItem = nil }
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
    HStack(spacing: 8) {
      // Activity indicator circle - shows when session is working
      Circle()
        .fill(isHighlighted ? Color.brandPrimary : .gray.opacity(0.3))
        .frame(width: 10, height: 10)
        .shadow(color: isHighlighted ? Color.brandPrimary.opacity(0.6) : .clear, radius: 4)

      // Session label and ID
      HStack(spacing: 4) {
        Text("Session:")
          .font(.subheadline)
          .foregroundColor(.secondary)
        Text(session.shortId)
          .font(.system(.subheadline, design: .monospaced))
          .fontWeight(.bold)
      }

      // Icon buttons for actions
      HStack(spacing: 4) {
        AnimatedCopyButton(action: onCopySessionId)

        Button(action: onOpenSessionFile) {
          Image(systemName: "doc.text")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("View session transcript")

        Button(action: onConnect) {
          Image(systemName: "rectangle.portrait.and.arrow.right")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Open in external Terminal")
      }

      Spacer()

      // Terminal/List segmented control
      HStack(spacing: 4) {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { onToggleTerminal(false) } }) {
          Image(systemName: "list.bullet")
            .font(.caption)
            .frame(width: 28, height: 22)
            .foregroundColor(!showTerminal ? .brandPrimary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { onToggleTerminal(true) } }) {
          Image(systemName: "terminal")
            .font(.caption)
            .frame(width: 28, height: 22)
            .foregroundColor(showTerminal ? .brandPrimary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .padding(4)
      .background(Color.secondary.opacity(0.12))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .animation(.easeInOut(duration: 0.2), value: showTerminal)

      // Close button (inline)
      Button(action: onStopMonitoring) {
        Image(systemName: "xmark")
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .help("Stop monitoring")
    }
  }

  // MARK: - Path Row

  private var pathRow: some View {
    HStack(spacing: 8) {
      // Folder icon and path
      HStack(spacing: 4) {
        Image(systemName: "folder")
          .font(.caption)
          .foregroundColor(.secondary)

        Text(session.projectPath)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      // Branch name in brand color
      if let branch = session.branchName {
        Text(branch)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundColor(.brandPrimary)
      }

      Spacer()

      // Pending changes preview button
      if let pendingToolUse = state?.pendingToolUse,
         pendingToolUse.isCodeChangeTool,
         case .awaitingApproval = state?.status {
        Button(action: {
          pendingChangesSheetItem = PendingChangesSheetItem(
            session: session,
            pendingToolUse: pendingToolUse
          )
        }) {
          HStack(spacing: 4) {
            Image(systemName: "eye")
              .font(.caption2)
            Text("Preview")
              .font(.caption2)
          }
          .foregroundColor(.orange)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.orange.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Preview pending \(pendingToolUse.toolName) change")
      }

      // Plan button
      if let planState = planState {
        Button(action: {
          planSheetItem = PlanSheetItem(
            session: session,
            planState: planState
          )
        }) {
          HStack(spacing: 4) {
            Image(systemName: "list.bullet.clipboard")
              .font(.caption2)
            Text("Plan")
              .font(.caption2)
          }
          .foregroundColor(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.secondary.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("View session plan")
      }

      // Diff button
      Button(action: {
        gitDiffSheetItem = GitDiffSheetItem(
          session: session,
          projectPath: session.projectPath
        )
      }) {
        HStack(spacing: 4) {
          Image(systemName: "arrow.left.arrow.right")
            .font(.caption2)
          Text("Diff")
            .font(.caption2)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .buttonStyle(.plain)
      .help("View git unstaged changes")

      // Terminal refresh button (only visible when terminal is shown)
      if showTerminal {
        Button(action: onRefreshTerminal) {
          HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
              .font(.caption2)
            Text("Refresh")
              .font(.caption2)
          }
          .foregroundColor(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.secondary.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Refresh terminal (reload session history)")
      }
    }
  }

  // MARK: - Monitor Content

  @ViewBuilder
  private var monitorContent: some View {
    if showTerminal {
      EmbeddedTerminalView(
        terminalKey: terminalKey ?? session.id,
        sessionId: session.id,
        projectPath: session.projectPath,
        claudeClient: claudeClient,
        initialPrompt: initialPrompt,
        viewModel: viewModel
      )
      .frame(minHeight: 300)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        Text("Recent Activity")
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.secondary)

        VStack(alignment: .leading, spacing: 16) {
          // Show recent activities (older first)
          if let state = state {
            ForEach(state.recentActivities.suffix(2).reversed()) { activity in
              FlatActivityRow(activity: activity)
            }
          }

          // Current status as the most recent item
          StatusActivityRow(
            status: state?.status ?? .idle,
            timestamp: state?.lastActivityAt ?? Date()
          )
        }
      }
    }
  }
}

// MARK: - Flat Activity Row

private struct FlatActivityRow: View {
  let activity: ActivityEntry

  private var iconColor: Color {
    switch activity.type {
    case .toolUse:
      return .orange
    case .toolResult(_, let success):
      return success ? .green : .red
    case .userMessage:
      return .blue
    case .assistantMessage:
      return .purple
    case .thinking:
      return .gray
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      Text(formatTime(activity.timestamp))
        .font(.system(.subheadline, design: .monospaced))
        .foregroundColor(.secondary)
        .monospacedDigit()

      Image(systemName: activity.type.icon)
        .font(.subheadline)
        .foregroundColor(iconColor)
        .frame(width: 18)

      Text(activity.description)
        .font(.subheadline)
        .lineLimit(1)
        .foregroundColor(.primary)
    }
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

// MARK: - Status Activity Row

/// Shows the current session status as an activity row
private struct StatusActivityRow: View {
  let status: SessionStatus
  let timestamp: Date

  private var statusColor: Color {
    switch status.color {
    case "blue": return .blue
    case "orange": return .orange
    case "yellow": return .yellow
    case "red": return .red
    default: return .gray
    }
  }

  private var statusIcon: String {
    switch status {
    case .idle:
      return "circle.fill"
    case .thinking:
      return "sparkles"
    case .executingTool:
      return "gearshape.fill"
    case .awaitingApproval:
      return "exclamationmark.circle.fill"
    case .waitingForUser:
      return "circle.fill"
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      Text(formatTime(timestamp))
        .font(.system(.subheadline, design: .monospaced))
        .foregroundColor(.secondary)
        .monospacedDigit()

      Image(systemName: statusIcon)
        .font(.subheadline)
        .foregroundColor(statusColor)
        .frame(width: 18)

      Text(status.displayName)
        .font(.subheadline)
        .foregroundColor(.primary)
    }
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

// MARK: - Animated Copy Button

/// Reusable copy button with animated checkmark confirmation
struct AnimatedCopyButton: View {
  let action: () -> Void
  var size: CGFloat = 24
  var iconFont: Font = .caption
  var showBackground: Bool = true

  @State private var showConfirmation = false

  var body: some View {
    Button {
      action()
      withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
        showConfirmation = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        withAnimation(.easeOut(duration: 0.2)) {
          showConfirmation = false
        }
      }
    } label: {
      Image(systemName: showConfirmation ? "checkmark" : "doc.on.doc")
        .font(iconFont)
        .fontWeight(showConfirmation ? .bold : .regular)
        .foregroundColor(showConfirmation ? .green : .secondary)
        .frame(width: size, height: size)
        .background(showBackground ? Color.secondary.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(.plain)
    .help("Copy session ID")
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    // Active session with slug
    MonitoringCardView(
      session: CLISession(
        id: "e1b8aae2-2a33-4402-a8f5-886c4d4da370",
        projectPath: "/Users/james/git/ClaudeCodeUI",
        branchName: "main",
        isWorktree: false,
        lastActivityAt: Date(),
        messageCount: 42,
        isActive: true,
        slug: "cryptic-orbiting-flame"
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
      onToggleTerminal: { _ in },
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )

    // Awaiting approval with slug
    MonitoringCardView(
      session: CLISession(
        id: "f2c9bbf3-3b44-5513-b9f6-997d5e5eb481",
        projectPath: "/Users/james/git/MyProject",
        branchName: "feature/auth",
        isWorktree: true,
        lastActivityAt: Date(),
        messageCount: 15,
        isActive: true,
        slug: "async-coalescing-summit"
      ),
      state: SessionMonitorState(
        status: .awaitingApproval(tool: "git"),
        lastActivityAt: Date(),
        model: "claude-sonnet-4-20250514",
        recentActivities: []
      ),
      onToggleTerminal: { _ in },
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )

    // Loading state (no slug - shows only session ID)
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
      onToggleTerminal: { _ in },
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {},
      onRefreshTerminal: {}
    )
  }
  .padding()
  .frame(width: 320)
}
