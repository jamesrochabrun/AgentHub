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
        // Status indicator and model
        HStack {
          StatusBadge(status: state.status)
          Spacer()
          if let model = state.model {
            ModelBadge(model: model)
          }
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
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 8) {
      // Animated indicator for active states
      ZStack {
        Circle()
          .fill(statusColor)
          .frame(width: DesignTokens.StatusSize.md, height: DesignTokens.StatusSize.md)
          .shadow(color: statusColor.opacity(0.5), radius: isActiveStatus ? 6 : 3)

        if isActiveStatus {
          Circle()
            .stroke(statusColor.opacity(0.3), lineWidth: 2)
            .frame(width: 18, height: 18)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0 : 1)
        }
      }

      Image(systemName: status.icon)
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(statusColor)

      Text(status.displayName)
        .font(.subheadline)
        .fontWeight(.medium)
        .foregroundColor(statusColor)
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(statusColor.opacity(0.12))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
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
