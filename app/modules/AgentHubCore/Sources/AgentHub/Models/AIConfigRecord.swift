//
//  AIConfigRecord.swift
//  AgentHub
//
//  GRDB record for persisted AI configuration per CLI provider.
//

import Foundation
import GRDB

/// Persisted AI configuration for a CLI provider (Claude or Codex).
/// One row per provider — keyed by provider string ("claude" or "codex").
public struct AIConfigRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "ai_config"

  /// Primary key: "claude" or "codex"
  public var provider: String
  /// Default model identifier (empty = use CLI default)
  public var defaultModel: String
  /// Effort / reasoning level: "low", "medium", "high" (empty = CLI default)
  public var effortLevel: String
  /// Comma-separated allowed tool patterns, Claude only (e.g. "Bash(npm *), Read, Edit")
  public var allowedTools: String
  /// Comma-separated disallowed tool patterns, Claude only
  public var disallowedTools: String
  /// Codex approval policy: "suggest", "auto-edit", "full-auto" (empty = CLI default)
  public var approvalPolicy: String
  /// Last update timestamp
  public var updatedAt: Date

  public init(
    provider: String,
    defaultModel: String = "",
    effortLevel: String = "",
    allowedTools: String = "",
    disallowedTools: String = "",
    approvalPolicy: String = "",
    updatedAt: Date = Date()
  ) {
    self.provider = provider
    self.defaultModel = defaultModel
    self.effortLevel = effortLevel
    self.allowedTools = allowedTools
    self.disallowedTools = disallowedTools
    self.approvalPolicy = approvalPolicy
    self.updatedAt = updatedAt
  }

  /// Parses a comma-separated tool patterns string into an array, trimming whitespace.
  public static func parseToolPatterns(_ raw: String?) -> [String] {
    guard let raw, !raw.isEmpty else { return [] }
    return raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}
