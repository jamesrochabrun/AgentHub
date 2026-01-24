//
//  SessionConversationView.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import SwiftUI

// MARK: - SessionConversationView

/// Main scrollable conversation view that displays messages from a Claude Code session.
/// Renders user messages, assistant responses, tool calls, and thinking indicators.
/// Uses ScrollViewReader for programmatic scroll-to-bottom on new messages.
public struct SessionConversationView: View {
  let messages: [ConversationMessage]
  let scrollToBottom: Bool

  /// Anchor ID for scroll-to-bottom behavior
  private let bottomAnchorID = "conversation-bottom"

  /// Computed property for the last message ID (used for change detection)
  private var lastMessageId: UUID? {
    messages.last?.id
  }

  /// Creates a new conversation view with the given messages.
  /// - Parameters:
  ///   - messages: The conversation messages to display
  ///   - scrollToBottom: Whether to automatically scroll to the bottom when new messages arrive (default: true)
  public init(messages: [ConversationMessage], scrollToBottom: Bool = true) {
    self.messages = messages
    self.scrollToBottom = scrollToBottom
  }

  public var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if messages.isEmpty {
            emptyState
          } else {
            ForEach(messages) { message in
              ConversationMessageView(
                message: message,
                toolResultMap: buildToolResultMap()
              )
              .id(message.id)
            }
          }

          // Invisible anchor for scroll-to-bottom
          Color.clear
            .frame(height: 1)
            .id(bottomAnchorID)
        }
        .padding(12)
      }
      .onChange(of: messages.count) { _, _ in
        scrollToBottomIfNeeded(proxy: proxy)
      }
      .onChange(of: lastMessageId) { _, _ in
        // Also scroll when the last message changes (even if count is the same)
        scrollToBottomIfNeeded(proxy: proxy)
      }
      .onAppear {
        if scrollToBottom && !messages.isEmpty {
          // Use DispatchQueue to ensure view is fully laid out
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
          }
        }
      }
    }
  }

  /// Scrolls to bottom with animation if scrollToBottom is enabled
  private func scrollToBottomIfNeeded(proxy: ScrollViewProxy) {
    guard scrollToBottom else { return }
    withAnimation(.easeOut(duration: 0.2)) {
      proxy.scrollTo(bottomAnchorID, anchor: .bottom)
    }
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 32))
        .foregroundColor(.secondary.opacity(0.5))

      Text("No messages yet")
        .font(.subheadline)
        .foregroundColor(.secondary)

      Text("Start a conversation or wait for activity")
        .font(.caption)
        .foregroundColor(.secondary.opacity(0.7))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  // MARK: - Tool Result Mapping

  /// Builds a map of tool use IDs to their results for rendering tool cards with status
  private func buildToolResultMap() -> [String: ToolCallCard.ToolResult] {
    var resultMap: [String: ToolCallCard.ToolResult] = [:]

    for message in messages {
      switch message.content {
      case .toolResult(_, let success, let toolUseId):
        resultMap[toolUseId] = success ? .success : .failure
      default:
        break
      }
    }

    // Mark pending tool uses that don't have results yet
    for message in messages {
      switch message.content {
      case .toolUse(_, _, let id):
        if resultMap[id] == nil {
          resultMap[id] = .pending
        }
      default:
        break
      }
    }

    return resultMap
  }
}

// MARK: - Preview

#Preview("Conversation with Messages") {
  SessionConversationView(
    messages: [
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-300),
        content: .user(text: "Can you help me build a conversation view for my macOS app?")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-290),
        content: .assistant(text: "I'd be happy to help! Let me explore your codebase first to understand the existing patterns.")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-280),
        content: .thinking
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-270),
        content: .toolUse(name: "Glob", input: "**/*.swift", id: "tool-1")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-260),
        content: .toolResult(name: "Glob", success: true, toolUseId: "tool-1")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-250),
        content: .toolUse(name: "Read", input: "/Users/james/project/SessionMonitorPanel.swift", id: "tool-2")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-240),
        content: .toolResult(name: "Read", success: true, toolUseId: "tool-2")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-230),
        content: .assistant(text: "I've found the relevant files. Now I'll create the new conversation view components.")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-220),
        content: .toolUse(name: "Write", input: "SessionConversationView.swift", id: "tool-3")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-210),
        content: .toolResult(name: "Write", success: true, toolUseId: "tool-3")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-200),
        content: .assistant(text: "Done! I've created the conversation view with full support for messages, tool calls, and thinking indicators.")
      )
    ],
    scrollToBottom: true
  )
  .frame(width: 450, height: 500)
}

#Preview("Empty State") {
  SessionConversationView(
    messages: [],
    scrollToBottom: true
  )
  .frame(width: 450, height: 300)
}

#Preview("Pending Tool") {
  SessionConversationView(
    messages: [
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-60),
        content: .user(text: "Build the project")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-50),
        content: .assistant(text: "I'll run the build command now.")
      ),
      ConversationMessage(
        timestamp: Date().addingTimeInterval(-40),
        content: .toolUse(name: "Bash", input: "swift build", id: "tool-pending")
      )
    ],
    scrollToBottom: true
  )
  .frame(width: 450, height: 300)
}
