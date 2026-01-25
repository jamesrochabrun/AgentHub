//
//  UserMessageBubble.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import SwiftUI

// MARK: - UserMessageBubble

/// Styled bubble for displaying user messages in the conversation view.
/// Follows the Steve Jobs design bar: simple, focused, native macOS feel.
public struct UserMessageBubble: View {
  let text: String
  let timestamp: Date

  /// Creates a new user message bubble.
  /// - Parameters:
  ///   - text: The user's message text
  ///   - timestamp: When the message was sent
  public init(text: String, timestamp: Date) {
    self.text = text
    self.timestamp = timestamp
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 10) {
      // User icon
      Image(systemName: "person.circle.fill")
        .font(.system(size: 20))
        .foregroundColor(Color.Chat.userPrimary)

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
        .fill(Color.Chat.userPrimary.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.Chat.userPrimary.opacity(0.15), lineWidth: 1)
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
    UserMessageBubble(
      text: "Can you help me add a new feature to the application?",
      timestamp: Date()
    )

    UserMessageBubble(
      text: "I want to create a conversation view that displays messages from a Claude Code session. It should show user messages, assistant responses, and tool calls in a clean, organized way.",
      timestamp: Date().addingTimeInterval(-120)
    )

    UserMessageBubble(
      text: "Build it",
      timestamp: Date().addingTimeInterval(-300)
    )
  }
  .padding()
  .frame(width: 400)
}
