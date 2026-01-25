//
//  AssistantMessageView.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import SwiftUI

// MARK: - AssistantMessageView

/// View for displaying assistant text responses in the conversation view.
/// Follows the Steve Jobs design bar: simple, focused, native macOS feel.
public struct AssistantMessageView: View {
  let text: String
  let timestamp: Date

  /// Creates a new assistant message view.
  /// - Parameters:
  ///   - text: The assistant's response text
  ///   - timestamp: When the message was generated
  public init(text: String, timestamp: Date) {
    self.text = text
    self.timestamp = timestamp
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // Assistant icon
      Image(systemName: "sparkles")
        .font(.system(size: 18))
        .foregroundColor(Color.Chat.assistantPrimary)
        .frame(width: 20, height: 20)

      VStack(alignment: .leading, spacing: 4) {
        // Timestamp
        Text(formatTime(timestamp))
          .font(.caption2)
          .foregroundColor(.secondary)

        // Message text
        Text(text)
          .font(.body)
          .foregroundColor(.primary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.Chat.assistantPrimary.opacity(0.06))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.Chat.assistantPrimary.opacity(0.12), lineWidth: 1)
    )
  }

  private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    AssistantMessageView(
      text: "I'll help you add that feature. Let me start by exploring the codebase to understand the current structure.",
      timestamp: Date()
    )

    AssistantMessageView(
      text: "Done! I've created the conversation view with the following components:\n\n1. SessionConversationView - Main scrollable view\n2. ConversationMessageView - Routes messages\n3. ToolCallCard - Shows tool invocations\n4. UserMessageBubble - User messages\n5. AssistantMessageView - This view",
      timestamp: Date().addingTimeInterval(-60)
    )

    AssistantMessageView(
      text: "Let me know if you need anything else.",
      timestamp: Date().addingTimeInterval(-30)
    )
  }
  .padding()
  .frame(width: 400)
}
