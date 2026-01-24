//
//  ToolCallCard.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import SwiftUI

// MARK: - ToolCallCard

/// Expandable card for displaying tool invocations in the conversation view.
/// Shows tool name with optional input preview, expandable for full details.
/// Follows the Steve Jobs design bar: simple, focused, native macOS feel.
public struct ToolCallCard: View {
  let toolName: String
  let input: String?
  let result: ToolResult?
  let timestamp: Date

  @State private var isExpanded: Bool = false

  /// Result state for the tool call
  public enum ToolResult: Equatable, Sendable {
    case pending
    case success
    case failure
  }

  /// Creates a new tool call card.
  /// - Parameters:
  ///   - toolName: The name of the tool being invoked (e.g., "Bash", "Read", "Edit")
  ///   - input: Optional preview of the tool input (e.g., command, file path)
  ///   - result: The result state of the tool call (pending, success, or failure)
  ///   - timestamp: When the tool was invoked
  public init(
    toolName: String,
    input: String? = nil,
    result: ToolResult? = nil,
    timestamp: Date
  ) {
    self.toolName = toolName
    self.input = input
    self.result = result
    self.timestamp = timestamp
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header row - always visible
      Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
        HStack(spacing: 8) {
          // Status indicator
          statusIcon
            .frame(width: 16, height: 16)

          // Tool name
          Text(toolName)
            .font(.system(.caption, design: .monospaced, weight: .semibold))
            .foregroundColor(statusColor)

          // Input preview (truncated)
          if let input = input, !input.isEmpty, !isExpanded {
            Text(input)
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          Spacer()

          // Timestamp
          Text(formatTime(timestamp))
            .font(.caption)
            .foregroundColor(.secondary)

          // Expand/collapse chevron
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Expanded content
      if isExpanded, let input = input, !input.isEmpty {
        Divider()
          .padding(.horizontal, 10)

        Text(input)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.primary.opacity(0.8))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(10)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(backgroundColor)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(borderColor, lineWidth: 1)
    )
  }

  // MARK: - Status Styling

  @ViewBuilder
  private var statusIcon: some View {
    switch result {
    case .success:
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(Color.Chat.toolResult)
    case .failure:
      Image(systemName: "xmark.circle.fill")
        .foregroundColor(Color.Chat.toolError)
    case .pending, .none:
      Image(systemName: "gearshape.fill")
        .foregroundColor(Color.Chat.toolUse)
    }
  }

  private var statusColor: Color {
    switch result {
    case .success:
      return Color.Chat.toolResult
    case .failure:
      return Color.Chat.toolError
    case .pending, .none:
      return Color.Chat.toolUse
    }
  }

  private var backgroundColor: Color {
    switch result {
    case .success:
      return Color.Chat.toolResult.opacity(0.06)
    case .failure:
      return Color.Chat.toolError.opacity(0.06)
    case .pending, .none:
      return Color.Chat.toolUse.opacity(0.06)
    }
  }

  private var borderColor: Color {
    switch result {
    case .success:
      return Color.Chat.toolResult.opacity(0.2)
    case .failure:
      return Color.Chat.toolError.opacity(0.2)
    case .pending, .none:
      return Color.Chat.toolUse.opacity(0.2)
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
  VStack(spacing: 12) {
    // Pending tool call
    ToolCallCard(
      toolName: "Bash",
      input: "swift build",
      result: .pending,
      timestamp: Date()
    )

    // Successful tool call with longer input
    ToolCallCard(
      toolName: "Read",
      input: "/Users/james/git/AgentHub/app/modules/AgentHubCore/Sources/AgentHub/UI/SessionMonitorPanel.swift",
      result: .success,
      timestamp: Date().addingTimeInterval(-30)
    )

    // Failed tool call
    ToolCallCard(
      toolName: "Edit",
      input: "file_path: /path/to/file.swift\nold_string: \"func test()\"\nnew_string: \"func test() async\"",
      result: .failure,
      timestamp: Date().addingTimeInterval(-60)
    )

    // Tool call without input
    ToolCallCard(
      toolName: "Glob",
      input: nil,
      result: .success,
      timestamp: Date().addingTimeInterval(-90)
    )
  }
  .padding()
  .frame(width: 350)
}
