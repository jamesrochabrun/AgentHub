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
  let onToggleTerminal: (Bool) -> Void
  let onStopMonitoring: () -> Void
  let onConnect: () -> Void
  let onCopySessionId: () -> Void
  let onOpenSessionFile: () -> Void
  let onInlineRequestSubmit: ((String, CLISession) -> Void)?
  let onPromptConsumed: (() -> Void)?

  @State private var codeChangesSheetItem: CodeChangesSheetItem?
  @State private var gitDiffSheetItem: GitDiffSheetItem?
  @State private var planSheetItem: PlanSheetItem?

  public init(
    session: CLISession,
    state: SessionMonitorState?,
    codeChangesState: CodeChangesState? = nil,
    planState: PlanState? = nil,
    claudeClient: (any ClaudeCode)? = nil,
    showTerminal: Bool = false,
    initialPrompt: String? = nil,
    onToggleTerminal: @escaping (Bool) -> Void,
    onStopMonitoring: @escaping () -> Void,
    onConnect: @escaping () -> Void,
    onCopySessionId: @escaping () -> Void,
    onOpenSessionFile: @escaping () -> Void,
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
    self.onToggleTerminal = onToggleTerminal
    self.onStopMonitoring = onStopMonitoring
    self.onConnect = onConnect
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
    self.onInlineRequestSubmit = onInlineRequestSubmit
    self.onPromptConsumed = onPromptConsumed
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header with session info and actions
      header

      Divider()

      // Status row with model and path
      statusRow

      // Monitoring panel content (reuses existing component)
      SessionMonitorPanel(
        state: state,
        showTerminal: showTerminal,
        sessionId: session.id,
        projectPath: session.projectPath,
        claudeClient: claudeClient,
        initialPrompt: initialPrompt,
        onPromptConsumed: onPromptConsumed
      )
    }
    .padding(12)
    .agentHubCard(isHighlighted: isHighlighted)
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
      // Session ID (adaptive - hides label when narrow)
      ViewThatFits(in: .horizontal) {
        // Wide: show label and ID
        HStack(spacing: 4) {
          Text("Session:")
            .font(.subheadline)
            .foregroundColor(.secondary)
          Text(session.shortId)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundColor(.secondary)
            .fontWeight(.bold)
        }

        // Narrow: just ID
        Text(session.shortId)
          .font(.system(.subheadline, design: .monospaced))
          .foregroundColor(.secondary)
          .fontWeight(.bold)
      }
      .lineLimit(1)

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

      // Open in external terminal button (right after transcript)
      Button(action: onConnect) {
        Image(systemName: "rectangle.portrait.and.arrow.right")
          .font(.caption)
          .foregroundColor(.secondary)
          .agentHubChip()
      }
      .buttonStyle(.plain)
      .help("Open in external Terminal")

      Spacer()

      // TEMPORARY: Disabling code changes button feature
      // TODO: Re-enable when code changes view is ready for production
      // if let codeChangesState, codeChangesState.changeCount > 0 {
      //   Button(action: {
      //     codeChangesSheetItem = CodeChangesSheetItem(
      //       session: session,
      //       codeChangesState: codeChangesState
      //     )
      //   }) {
      //     HStack(spacing: 4) {
      //       Image(systemName: "chevron.left.forwardslash.chevron.right")
      //         .font(.caption)
      //       Text("\(codeChangesState.changeCount)")
      //         .font(.system(.caption2, design: .rounded))
      //     }
      //     .foregroundColor(.brandPrimary)
      //     .agentHubChip()
      //   }
      //   .buttonStyle(.plain)
      //   .help("View code changes")
      // }

      // Terminal/List segmented control (custom capsule style)
      HStack(spacing: 0) {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { onToggleTerminal(false) } }) {
          Image(systemName: "list.bullet")
            .font(.caption)
            .frame(width: 28, height: 20)
            .foregroundColor(!showTerminal ? .white : .secondary)
            .background(!showTerminal ? Color.brandPrimary : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)

        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { onToggleTerminal(true) } }) {
          Image(systemName: "terminal")
            .font(.caption)
            .frame(width: 28, height: 20)
            .foregroundColor(showTerminal ? .white : .secondary)
            .background(showTerminal ? Color.brandPrimary : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
      .padding(2)
      .background(Color.secondary.opacity(0.15))
      .clipShape(Capsule())
      .animation(.easeInOut(duration: 0.2), value: showTerminal)

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
    HStack(spacing: 6) {
      pathView
      branchPill

      Spacer()

      // Plan button (if plan detected)
      if let planState = planState {
        Button(action: {
          planSheetItem = PlanSheetItem(
            session: session,
            planState: planState
          )
        }) {
          HStack(spacing: 4) {
            Image(systemName: "list.bullet.clipboard")
              .font(.caption)
            Text("Plan")
              .font(.system(.caption2, design: .rounded))
          }
          .foregroundColor(.secondary)
          .agentHubChip()
        }
        .buttonStyle(.plain)
        .help("View session plan")
      }

      // Git diff button (always visible)
      Button(action: {
        gitDiffSheetItem = GitDiffSheetItem(
          session: session,
          projectPath: session.projectPath
        )
      }) {
        HStack(spacing: 4) {
          Image(systemName: "arrow.left.arrow.right")
            .font(.caption)
          Text("Diff")
            .font(.system(.caption2, design: .rounded))
        }
        .foregroundColor(.secondary)
        .agentHubChip()
      }
      .buttonStyle(.plain)
      .help("View git unstaged changes")
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
        .fontWeight(.bold)
        .foregroundColor(.secondary)
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
      onToggleTerminal: { _ in },
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
      onToggleTerminal: { _ in },
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
      onToggleTerminal: { _ in },
      onStopMonitoring: {},
      onConnect: {},
      onCopySessionId: {},
      onOpenSessionFile: {}
    )
  }
  .padding()
  .frame(width: 320)
}
