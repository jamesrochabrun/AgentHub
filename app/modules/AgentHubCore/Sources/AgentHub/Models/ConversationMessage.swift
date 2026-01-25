//
//  ConversationMessage.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import Foundation

// MARK: - ConversationMessage

/// Represents a message in a conversation view parsed from session activity.
/// Used to display user/assistant messages, tool calls, and thinking in
/// `SessionConversationView`.
public struct ConversationMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let content: MessageContent

  public init(
    id: UUID = UUID(),
    timestamp: Date,
    content: MessageContent
  ) {
    self.id = id
    self.timestamp = timestamp
    self.content = content
  }

  // MARK: - MessageContent

  /// The type of content this message represents
  public enum MessageContent: Equatable, Sendable {
    /// A message from the user
    case user(text: String)

    /// A text response from the assistant
    case assistant(text: String)

    /// A tool invocation by the assistant
    /// - Parameters:
    ///   - name: The name of the tool being invoked
    ///   - input: Optional preview of the tool input (e.g., filename, command)
    ///   - id: The unique tool use ID for matching with results
    case toolUse(name: String, input: String?, id: String)

    /// The result of a tool invocation
    /// - Parameters:
    ///   - name: The name of the tool that was invoked
    ///   - success: Whether the tool completed successfully
    ///   - toolUseId: The tool use ID this result corresponds to
    case toolResult(name: String, success: Bool, toolUseId: String)

    /// A thinking block from the assistant (extended thinking mode)
    case thinking
  }
}

// MARK: - SessionViewMode

/// The view mode for displaying a session's content.
/// Used in `SessionMonitorPanel` to toggle between terminal, conversation, and headless views.
public enum SessionViewMode: String, Sendable, CaseIterable {
  /// Show the raw terminal output (existing behavior, default)
  case terminal

  /// Show the structured conversation view (parses terminal output)
  case conversation

  /// Show the headless conversation view (spawns Claude with --output-format stream-json)
  case headless
}
