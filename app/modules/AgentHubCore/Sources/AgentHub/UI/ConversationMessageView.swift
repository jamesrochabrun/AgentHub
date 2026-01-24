//
//  ConversationMessageView.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import SwiftUI

// MARK: - ConversationMessageView

/// Routes a `ConversationMessage` to the appropriate renderer based on its content type.
/// This is the main switch for rendering different message types in the conversation view.
public struct ConversationMessageView: View {
  let message: ConversationMessage

  /// Tracking state for tool results to match with their corresponding tool uses
  var toolResultMap: [String: ToolCallCard.ToolResult]

  /// Creates a new conversation message view.
  /// - Parameters:
  ///   - message: The conversation message to render
  ///   - toolResultMap: Map of tool use IDs to their results for rendering tool call status
  public init(message: ConversationMessage, toolResultMap: [String: ToolCallCard.ToolResult] = [:]) {
    self.message = message
    self.toolResultMap = toolResultMap
  }

  public var body: some View {
    switch message.content {
    case .user(let text):
      UserMessageBubble(text: text, timestamp: message.timestamp)

    case .assistant(let text):
      AssistantMessageView(text: text, timestamp: message.timestamp)

    case .toolUse(let name, let input, let id):
      ToolCallCard(
        toolName: name,
        input: input,
        result: toolResultMap[id],
        timestamp: message.timestamp
      )

    case .toolResult(_, _, _):
      // Tool results are rendered as part of their corresponding tool use card
      EmptyView()

    case .thinking:
      ThinkingIndicator(timestamp: message.timestamp)
    }
  }
}

// MARK: - ThinkingIndicator

/// Indicator for Claude's thinking/reasoning blocks
private struct ThinkingIndicator: View {
  let timestamp: Date

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "brain")
        .font(.caption)
        .foregroundColor(Color.Chat.thinking)

      Text("Thinking...")
        .font(.caption)
        .foregroundColor(Color.Chat.thinking)

      Spacer()

      Text(formatTime(timestamp))
        .font(.caption2)
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.Chat.thinking.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.Chat.thinking.opacity(0.15), lineWidth: 1)
    )
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }
}

// MARK: - Preview

#Preview {
  ScrollView {
    VStack(spacing: 12) {
      // User message
      ConversationMessageView(
        message: ConversationMessage(
          timestamp: Date().addingTimeInterval(-300),
          content: .user(text: "Can you help me build a conversation view?")
        )
      )

      // Assistant response
      ConversationMessageView(
        message: ConversationMessage(
          timestamp: Date().addingTimeInterval(-290),
          content: .assistant(text: "I'll help you build that. Let me start by exploring the codebase.")
        )
      )

      // Thinking
      ConversationMessageView(
        message: ConversationMessage(
          timestamp: Date().addingTimeInterval(-280),
          content: .thinking
        )
      )

      // Tool use (pending)
      ConversationMessageView(
        message: ConversationMessage(
          timestamp: Date().addingTimeInterval(-270),
          content: .toolUse(name: "Read", input: "/path/to/file.swift", id: "tool-1")
        )
      )

      // Tool use (with result)
      ConversationMessageView(
        message: ConversationMessage(
          timestamp: Date().addingTimeInterval(-260),
          content: .toolUse(name: "Bash", input: "swift build", id: "tool-2")
        ),
        toolResultMap: ["tool-2": .success]
      )

      // Tool result
      ConversationMessageView(
        message: ConversationMessage(
          timestamp: Date().addingTimeInterval(-250),
          content: .toolResult(name: "Bash", success: true, toolUseId: "tool-2")
        )
      )

      // Failed tool
      ConversationMessageView(
        message: ConversationMessage(
          timestamp: Date().addingTimeInterval(-240),
          content: .toolResult(name: "Edit", success: false, toolUseId: "tool-3")
        )
      )
    }
    .padding()
  }
  .frame(width: 400, height: 600)
}
