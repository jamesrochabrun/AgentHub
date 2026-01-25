//
//  ClaudeSession.swift
//  AgentHub
//
//  Session state for Claude Code headless mode.
//

import Foundation

// MARK: - ClaudeSession

/// Represents an active or completed Claude Code headless session.
/// Used to track session metadata and enable resumption.
public struct ClaudeSession: Identifiable, Sendable, Equatable, Codable {
  /// The unique session identifier from Claude Code
  public let sessionId: String

  /// The model being used (e.g., "claude-sonnet-4-20250514")
  public let model: String?

  /// Tools available in this session
  public let tools: [String]?

  /// Working directory for this session
  public let cwd: String?

  public var id: String { sessionId }

  public init(
    sessionId: String,
    model: String? = nil,
    tools: [String]? = nil,
    cwd: String? = nil
  ) {
    self.sessionId = sessionId
    self.model = model
    self.tools = tools
    self.cwd = cwd
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case model
    case tools
    case cwd
  }
}
