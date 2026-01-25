//
//  SessionMonitorPanel.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import ClaudeCodeSDK
import SwiftUI

// MARK: - SessionMonitorPanel

/// Real-time monitoring panel showing current session status and recent activity.
/// Supports three view modes:
/// - `.conversation`: Shows structured conversation view with messages and tool calls (parses terminal output)
/// - `.headless`: Shows headless conversation view (spawns Claude with streaming JSON)
/// - `.terminal`: Shows raw terminal output (SwiftTerm)
/// Note: Only shows real-time data, not cumulative stats (which are misleading for continued sessions)
public struct SessionMonitorPanel: View {
  let state: SessionMonitorState?
  let showTerminal: Bool
  let viewMode: SessionViewMode
  let terminalKey: String?  // Key for terminal storage (session ID or "pending-{pendingId}")
  let sessionId: String?
  let projectPath: String?
  let claudeClient: (any ClaudeCode)?
  let initialPrompt: String?
  let viewModel: CLISessionsViewModel?
  let headlessViewModel: HeadlessSessionViewModel?
  let onPromptConsumed: (() -> Void)?
  let onSendMessage: ((String) -> Void)?

  public init(
    state: SessionMonitorState?,
    showTerminal: Bool = false,
    viewMode: SessionViewMode = .terminal,
    terminalKey: String? = nil,
    sessionId: String? = nil,
    projectPath: String? = nil,
    claudeClient: (any ClaudeCode)? = nil,
    initialPrompt: String? = nil,
    viewModel: CLISessionsViewModel? = nil,
    headlessViewModel: HeadlessSessionViewModel? = nil,
    onPromptConsumed: (() -> Void)? = nil,
    onSendMessage: ((String) -> Void)? = nil
  ) {
    self.state = state
    self.showTerminal = showTerminal
    self.viewMode = viewMode
    self.terminalKey = terminalKey
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.claudeClient = claudeClient
    self.initialPrompt = initialPrompt
    self.viewModel = viewModel
    self.headlessViewModel = headlessViewModel
    self.onPromptConsumed = onPromptConsumed
    self.onSendMessage = onSendMessage
  }

  /// Computed conversation messages from activity entries
  private var conversationMessages: [ConversationMessage] {
    guard let activities = state?.recentActivities else { return [] }
    return ConversationParser.parse(activities: activities)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Status indicator (only when state exists and not in terminal mode)
      if let state = state {
        if !showTerminal {
          HStack {
            StatusBadge(status: state.status)
            Spacer()
          }
        }

        // Context window usage bar (always visible)
        if state.inputTokens > 0 {
          ContextWindowBar(
            percentage: state.contextWindowUsagePercentage,
            formattedUsage: state.formattedContextUsage,
            model: state.model
          )
        }
      }

      // ZStack preserves all views to maintain state when switching modes
      ZStack {
        // Conversation view (parses terminal output)
        Group {
          if state != nil {
            SessionConversationView(
              messages: conversationMessages,
              scrollToBottom: true,
              onSendMessage: onSendMessage
            )
          } else {
            loadingView
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(viewMode == .conversation && !showTerminal ? 1 : 0)

        // Headless conversation view (spawns Claude with streaming JSON)
        Group {
          if let headlessVM = headlessViewModel {
            HeadlessConversationView(
              viewModel: headlessVM,
              workingDirectory: URL(fileURLWithPath: projectPath ?? NSHomeDirectory())
            )
          } else {
            // Fallback: show placeholder if headless view model not provided
            VStack(spacing: 12) {
              Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
              Text("Headless Mode")
                .font(.headline)
              Text("Not configured")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(viewMode == .headless && !showTerminal ? 1 : 0)

        // Activity list (legacy compact view, shown when not in conversation mode)
        Group {
          if let state = state {
            if !state.recentActivities.isEmpty {
              RecentActivityList(activities: state.recentActivities)
            }
          } else {
            loadingView
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(viewMode == .terminal && !showTerminal ? 1 : 0)

        // Terminal view (preserved in hierarchy to maintain SwiftTerm state)
        EmbeddedTerminalView(
          terminalKey: terminalKey ?? sessionId ?? "",
          sessionId: sessionId,
          projectPath: projectPath ?? "",
          claudeClient: claudeClient,
          initialPrompt: initialPrompt,
          viewModel: viewModel
        )
        .frame(minHeight: showTerminal ? 300 : 0, maxHeight: showTerminal ? .infinity : 0)
        .clipped()
        .cornerRadius(6)
        .opacity(showTerminal ? 1 : 0)
        .onAppear {
          // Clear the pending prompt after terminal starts
          if initialPrompt != nil {
            onPromptConsumed?()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.gray.opacity(0.05))
    .cornerRadius(8)
  }

  // MARK: - Loading View

  private var loadingView: some View {
    HStack {
      ProgressView()
        .scaleEffect(0.7)
      Text("Loading session data...")
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
  }
}

// MARK: - StatusBadge

private struct StatusBadge: View {
  let status: SessionStatus
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 6) {
      // Animated indicator for active states
      ZStack {
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)
          .shadow(color: statusColor.opacity(0.5), radius: isActiveStatus ? 4 : 2)

        if isActiveStatus {
          Circle()
            .stroke(statusColor.opacity(0.3), lineWidth: 1)
            .frame(width: 10, height: 10)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0 : 1)
        }
      }

      Text(status.displayName)
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(statusColor)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      Capsule()
        .fill(statusColor.opacity(0.12))
    )
    .overlay(
      Capsule()
        .stroke(statusColor.opacity(0.25), lineWidth: 1)
    )
    .onAppear {
      if isActiveStatus {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
          pulse = true
        }
      }
    }
    .onChange(of: isActiveStatus) { _, newValue in
      if newValue {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
          pulse = true
        }
      } else {
        pulse = false
      }
    }
  }

  private var isActiveStatus: Bool {
    switch status {
    case .thinking, .executingTool:
      return true
    default:
      return false
    }
  }

  private var statusColor: Color {
    switch status.color {
    case "blue": return .blue
    case "orange": return .orange
    case "yellow": return .yellow
    case "red": return .red
    default: return .gray
    }
  }
}

// MARK: - ModelBadge

struct ModelBadge: View {
  let model: String

  private var displayName: String {
    let lowercased = model.lowercased()
    if lowercased.contains("opus") { return "Opus" }
    if lowercased.contains("sonnet") { return "Sonnet" }
    if lowercased.contains("haiku") { return "Haiku" }
    return model
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "cpu")
        .font(.caption2)
      Text(displayName)
        .font(.caption)
    }
    .foregroundColor(.secondary)
  }
}

// MARK: - RecentActivityList

private struct RecentActivityList: View {
  let activities: [ActivityEntry]

  private var recentActivities: [ActivityEntry] {
    Array(activities.suffix(3).reversed())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Recent Activity")
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundColor(.secondary)

      ForEach(recentActivities) { activity in
        ActivityRow(activity: activity)
      }
    }
  }
}

// MARK: - ActivityRow

private struct ActivityRow: View {
  let activity: ActivityEntry

  var body: some View {
    HStack(spacing: 8) {
      Text(formatTime(activity.timestamp))
        .font(.caption2)
        .foregroundColor(.secondary)
        .monospacedDigit()
        .frame(width: 55, alignment: .leading)

      Image(systemName: activity.type.icon)
        .font(.caption2)
        .foregroundColor(iconColor)
        .frame(width: 14)

      Text(activity.description)
        .font(.caption2)
        .lineLimit(1)
        .foregroundColor(.primary)
    }
    .padding(.vertical, 2)
  }

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

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

// MARK: - Preview

#Preview("Activity List Mode") {
  VStack(spacing: 20) {
    // Active session - executing tool with context usage (activity list mode)
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        currentTool: "Bash",
        lastActivityAt: Date(),
        inputTokens: 45000,
        outputTokens: 1200,
        totalOutputTokens: 5600,
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date().addingTimeInterval(-15), type: .userMessage, description: "Build the project"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-10), type: .toolUse(name: "Bash"), description: "swift build"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-5), type: .toolResult(name: "Bash", success: true), description: "Completed"),
          ActivityEntry(timestamp: Date(), type: .thinking, description: "Thinking...")
        ]
      ),
      viewMode: .terminal  // Activity list shows when terminal mode but not showing terminal
    )

    // Loading
    SessionMonitorPanel(state: nil, viewMode: .terminal)
  }
  .padding()
  .frame(width: 350)
}

#Preview("Conversation Mode") {
  // Conversation view with structured messages
  SessionMonitorPanel(
    state: SessionMonitorState(
      status: .executingTool(name: "Read"),
      currentTool: "Read",
      lastActivityAt: Date(),
      inputTokens: 45000,
      outputTokens: 1200,
      totalOutputTokens: 5600,
      model: "claude-opus-4-20250514",
      recentActivities: [
        ActivityEntry(timestamp: Date().addingTimeInterval(-60), type: .userMessage, description: "Can you help me build a conversation view?"),
        ActivityEntry(timestamp: Date().addingTimeInterval(-55), type: .assistantMessage, description: "I'd be happy to help! Let me explore your codebase first."),
        ActivityEntry(timestamp: Date().addingTimeInterval(-50), type: .thinking, description: "Thinking..."),
        ActivityEntry(timestamp: Date().addingTimeInterval(-45), type: .toolUse(name: "Glob"), description: "**/*.swift"),
        ActivityEntry(timestamp: Date().addingTimeInterval(-40), type: .toolResult(name: "Glob", success: true), description: "Found 42 files"),
        ActivityEntry(timestamp: Date().addingTimeInterval(-35), type: .toolUse(name: "Read"), description: "/path/to/SessionMonitorPanel.swift"),
        ActivityEntry(timestamp: Date().addingTimeInterval(-30), type: .toolResult(name: "Read", success: true), description: "Read 400 lines"),
        ActivityEntry(timestamp: Date().addingTimeInterval(-25), type: .assistantMessage, description: "I've found the relevant files. Now I'll create the new components.")
      ]
    ),
    viewMode: .conversation
  )
  .padding()
  .frame(width: 450, height: 500)
}

#Preview("Terminal Visible") {
  VStack(alignment: .leading) {
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .thinking,
        lastActivityAt: Date(),
        inputTokens: 32000,
        outputTokens: 500,
        totalOutputTokens: 2000,
        model: "claude-sonnet-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date().addingTimeInterval(-10), type: .userMessage, description: "Run diagnostics"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-8), type: .toolUse(name: "Bash"), description: "echo 'Hello'"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-5), type: .toolResult(name: "Bash", success: true), description: "Completed")
        ]
      ),
      showTerminal: true,
      viewMode: .terminal,
      terminalKey: "preview-terminal",
      sessionId: nil,
      projectPath: NSHomeDirectory(),
      claudeClient: nil,
      initialPrompt: "echo 'Hello from preview'",
      viewModel: nil,
      onPromptConsumed: nil
    )
    .frame(minHeight: 320)
  }
  .padding(16)
  .frame(width: 700, height: 420, alignment: .topLeading)
  .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Headless Mode") {
  HeadlessModeActivePreview()
}

#Preview("Headless Mode - Empty") {
  HeadlessModeEmptyPreview()
}

#Preview("Headless Mode - With Tool Approval") {
  HeadlessModeApprovalPreview()
}

// MARK: - Headless Mode Preview Helpers

private struct HeadlessModeEmptyPreview: View {
  @State private var headlessVM = HeadlessSessionViewModel()

  var body: some View {
    SessionMonitorPanel(
      state: nil,
      showTerminal: false,
      viewMode: .headless,
      headlessViewModel: headlessVM
    )
    .padding()
    .frame(width: 450, height: 400)
  }
}

private struct HeadlessModeActivePreview: View {
  @State private var headlessVM = HeadlessSessionViewModel()

  var body: some View {
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        currentTool: "Bash",
        lastActivityAt: Date(),
        inputTokens: 32000,
        outputTokens: 1200,
        totalOutputTokens: 4800,
        model: "claude-sonnet-4-20250514",
        recentActivities: []
      ),
      showTerminal: false,
      viewMode: .headless,
      projectPath: NSHomeDirectory(),
      headlessViewModel: headlessVM
    )
    .onAppear {
      headlessVM.messages = [
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-60),
          content: .user(text: "Help me set up a new Swift package")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-55),
          content: .assistant(text: "I'll help you create a new Swift package. Let me start by setting up the basic structure.")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-50),
          content: .toolUse(name: "Bash", input: "swift package init --type library", id: "tool-1")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-45),
          content: .toolResult(name: "Bash", success: true, toolUseId: "tool-1")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-40),
          content: .assistant(text: "The package has been initialized. Now let me add some basic dependencies.")
        )
      ]
    }
    .padding()
    .frame(width: 500, height: 500)
  }
}

private struct HeadlessModeApprovalPreview: View {
  @State private var headlessVM = HeadlessSessionViewModel()

  var body: some View {
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .idle,
        lastActivityAt: Date(),
        inputTokens: 25000,
        outputTokens: 800,
        totalOutputTokens: 2400,
        model: "claude-sonnet-4-20250514",
        recentActivities: []
      ),
      showTerminal: false,
      viewMode: .headless,
      projectPath: NSHomeDirectory(),
      headlessViewModel: headlessVM
    )
    .onAppear {
      headlessVM.messages = [
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-30),
          content: .user(text: "Delete all .tmp files in this directory")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-25),
          content: .assistant(text: "I'll help you clean up the temporary files. Let me first find and then delete them.")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-20),
          content: .toolUse(name: "Bash", input: "find . -name '*.tmp' -type f", id: "tool-1")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-15),
          content: .toolResult(name: "Bash", success: true, toolUseId: "tool-1")
        ),
        ConversationMessage(
          timestamp: Date().addingTimeInterval(-10),
          content: .assistant(text: "Found 5 temporary files. I'll delete them now.")
        )
      ]
      headlessVM.pendingToolApproval = ClaudeControlRequestEvent(
        requestId: "approval-123",
        request: .canUseTool(
          toolName: "Bash",
          input: JSONValue(["command": "rm -f *.tmp"]),
          toolUseId: "tool-2"
        )
      )
    }
    .padding()
    .frame(width: 500, height: 500)
  }
}

#Preview("All Components") {
  VStack(spacing: 16) {
    // Conversation mode panel
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        currentTool: "Bash",
        lastActivityAt: Date(),
        inputTokens: 54000,
        outputTokens: 1800,
        totalOutputTokens: 7200,
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date().addingTimeInterval(-20), type: .userMessage, description: "Install dependencies"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-15), type: .toolUse(name: "Bash"), description: "brew install swiftlint"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-5), type: .toolResult(name: "Bash", success: true), description: "Completed")
        ]
      ),
      showTerminal: false,
      viewMode: .conversation
    )

    // Terminal mode panel
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .thinking,
        lastActivityAt: Date(),
        inputTokens: 54000,
        outputTokens: 2000,
        totalOutputTokens: 7800,
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date().addingTimeInterval(-20), type: .userMessage, description: "Install dependencies"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-15), type: .toolUse(name: "Bash"), description: "brew install swiftlint"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-5), type: .toolResult(name: "Bash", success: true), description: "Completed")
        ]
      ),
      showTerminal: true,
      viewMode: .terminal,
      terminalKey: "preview-terminal-all",
      sessionId: nil,
      projectPath: NSHomeDirectory(),
      claudeClient: nil,
      initialPrompt: "echo 'All components preview'",
      viewModel: nil,
      onPromptConsumed: nil
    )
    .frame(minHeight: 320)
  }
  .padding(16)
  .frame(width: 760, height: 720, alignment: .top)
  .background(Color(NSColor.windowBackgroundColor))
}

