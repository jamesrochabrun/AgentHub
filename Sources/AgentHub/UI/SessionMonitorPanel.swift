//
//  SessionMonitorPanel.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import ClaudeCodeSDK
import SwiftUI

// MARK: - SessionMonitorPanel

/// Real-time monitoring panel showing current session status and recent activity
/// Note: Only shows real-time data, not cumulative stats (which are misleading for continued sessions)
public struct SessionMonitorPanel: View {
  let state: SessionMonitorState?
  let showTerminal: Bool
  let sessionId: String?
  let projectPath: String?
  let claudeClient: (any ClaudeCode)?

  public init(
    state: SessionMonitorState?,
    showTerminal: Bool = false,
    sessionId: String? = nil,
    projectPath: String? = nil,
    claudeClient: (any ClaudeCode)? = nil
  ) {
    self.state = state
    self.showTerminal = showTerminal
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.claudeClient = claudeClient
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let state = state {
        // Status indicator and model
        HStack {
          StatusBadge(status: state.status)
          Spacer()
          if let model = state.model {
            ModelBadge(model: model)
          }
        }

        // Context window usage bar
        if state.inputTokens > 0 {
          ContextWindowBar(
            percentage: state.contextWindowUsagePercentage,
            formattedUsage: state.formattedContextUsage
          )
        }

        // Show terminal or activity list based on mode
        if showTerminal, let sessionId = sessionId {
          EmbeddedTerminalView(
            sessionId: sessionId,
            projectPath: projectPath ?? "",
            claudeClient: claudeClient
          )
          .frame(minHeight: 300)
          .cornerRadius(6)
        } else if !state.recentActivities.isEmpty {
          RecentActivityList(activities: state.recentActivities)
        }
      } else {
        // Loading state
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
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color.gray.opacity(0.05))
    .cornerRadius(8)
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

#Preview {
  VStack(spacing: 20) {
    // Active session - executing tool with context usage
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        currentTool: "Bash",
        lastActivityAt: Date(),
        inputTokens: 45000,  // Context window usage
        outputTokens: 1200,
        totalOutputTokens: 5600,
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date().addingTimeInterval(-15), type: .userMessage, description: "Build the project"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-10), type: .toolUse(name: "Bash"), description: "swift build"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-5), type: .toolResult(name: "Bash", success: true), description: "Completed"),
          ActivityEntry(timestamp: Date(), type: .thinking, description: "Thinking...")
        ]
      )
    )

    // High context usage (warning)
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .thinking,
        lastActivityAt: Date(),
        inputTokens: 160000,  // 80% usage
        outputTokens: 800,
        totalOutputTokens: 12000,
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date(), type: .thinking, description: "Thinking...")
        ]
      )
    )

    // Idle session
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .idle,
        lastActivityAt: Date().addingTimeInterval(-60),
        model: "claude-sonnet-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date().addingTimeInterval(-60), type: .assistantMessage, description: "Done! Let me know if you need anything else.")
        ]
      )
    )

    // Loading
    SessionMonitorPanel(state: nil)
  }
  .padding()
  .frame(width: 350)
}
