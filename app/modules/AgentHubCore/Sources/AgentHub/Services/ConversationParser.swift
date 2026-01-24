//
//  ConversationParser.swift
//  AgentHub
//
//  Created by Assistant on 1/24/26.
//

import Foundation

// MARK: - ConversationParser

/// Transforms `ActivityEntry` items from `SessionMonitorState` into
/// `ConversationMessage` items for display in `SessionConversationView`.
///
/// The parser converts the activity log entries (which track tool invocations,
/// messages, etc.) into a format suitable for rendering in a chat-like interface.
public struct ConversationParser {

  // MARK: - Public API

  /// Converts activity entries from the session monitor into conversation messages.
  ///
  /// Each `ActivityEntry` is transformed into a corresponding `ConversationMessage`
  /// based on its type:
  /// - `.userMessage` -> `.user(text:)`
  /// - `.assistantMessage` -> `.assistant(text:)`
  /// - `.toolUse(name:)` -> `.toolUse(name:input:id:)`
  /// - `.toolResult(name:success:)` -> `.toolResult(name:success:toolUseId:)`
  /// - `.thinking` -> `.thinking`
  ///
  /// - Parameter activities: The activity entries to convert
  /// - Returns: An array of conversation messages in the same order
  public static func parse(activities: [ActivityEntry]) -> [ConversationMessage] {
    // Track tool use IDs to match tool_use with tool_result
    // ActivityEntry doesn't store tool_use_id directly, so we track by position
    var toolUseIdStack: [String] = []

    return activities.compactMap { entry -> ConversationMessage? in
      let content: ConversationMessage.MessageContent

      switch entry.type {
      case .userMessage:
        // Skip empty user messages (may be just tool result carriers)
        guard !entry.description.isEmpty else { return nil }
        content = .user(text: entry.description)

      case .assistantMessage:
        content = .assistant(text: entry.description)

      case .toolUse(let name):
        // Generate a tool use ID based on the entry's UUID
        // This ensures consistent matching between tool_use and tool_result
        let toolUseId = entry.id.uuidString
        toolUseIdStack.append(toolUseId)

        // Use the description as input preview (SessionJSONLParser already extracts this)
        let inputPreview = entry.description != name ? entry.description : nil
        content = .toolUse(name: name, input: inputPreview, id: toolUseId)

      case .toolResult(let name, let success):
        // Pop the most recent tool use ID for matching
        // Note: This assumes tool results come in order after their corresponding tool uses
        let toolUseId = toolUseIdStack.isEmpty ? UUID().uuidString : toolUseIdStack.removeLast()
        content = .toolResult(name: name, success: success, toolUseId: toolUseId)

      case .thinking:
        content = .thinking
      }

      return ConversationMessage(
        id: entry.id,
        timestamp: entry.timestamp,
        content: content
      )
    }
  }

  // MARK: - Initialization

  /// Private initializer - use static `parse` method
  private init() {}
}
