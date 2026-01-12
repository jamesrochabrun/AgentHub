//
//  SessionMonitorPanel.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import SwiftUI

// MARK: - SessionMonitorPanel

/// Real-time monitoring panel showing current session status and recent activity
/// Note: Only shows real-time data, not cumulative stats (which are misleading for continued sessions)
public struct SessionMonitorPanel: View {
  let state: SessionMonitorState?

  public init(state: SessionMonitorState?) {
    self.state = state
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let state = state {
        // Status indicator
        StatusBadge(status: state.status)

        // Model (if available)
        if let model = state.model {
          ModelBadge(model: model)
        }

        // Recent activity
        if !state.recentActivities.isEmpty {
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

  var body: some View {
    HStack(spacing: 8) {
      // Animated indicator for active states
      if isActiveStatus {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
          .overlay(
            Circle()
              .stroke(statusColor.opacity(0.5), lineWidth: 2)
              .scaleEffect(1.5)
          )
      } else {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
      }

      Image(systemName: status.icon)
        .font(.caption)
        .foregroundColor(statusColor)

      Text(status.displayName)
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(statusColor)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(statusColor.opacity(0.1))
    .cornerRadius(6)
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

private struct ModelBadge: View {
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
    // Active session - executing tool
    SessionMonitorPanel(
      state: SessionMonitorState(
        status: .executingTool(name: "Bash"),
        currentTool: "Bash",
        lastActivityAt: Date(),
        model: "claude-opus-4-20250514",
        recentActivities: [
          ActivityEntry(timestamp: Date().addingTimeInterval(-15), type: .userMessage, description: "Build the project"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-10), type: .toolUse(name: "Bash"), description: "swift build"),
          ActivityEntry(timestamp: Date().addingTimeInterval(-5), type: .toolResult(name: "Bash", success: true), description: "Completed"),
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
