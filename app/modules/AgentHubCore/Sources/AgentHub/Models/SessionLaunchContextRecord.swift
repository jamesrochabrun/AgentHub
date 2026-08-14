//
//  SessionLaunchContextRecord.swift
//  AgentHub
//
//  SQLite record for the curated launch context attached to a session.
//
//  Launch context is delivered out-of-band (Claude `--append-system-prompt`,
//  Codex `-c developer_instructions=`) instead of inside the first user
//  message, so it is not part of the conversation history and would be lost
//  on resume. This row lets a resume launch re-pass the exact text the
//  session started with.
//

import Foundation
import GRDB

public struct SessionLaunchContextRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public var sessionId: String
  public var provider: String
  public var projectPath: String
  /// The exact text passed at launch: either the inline `<context>` block or
  /// the short file-reference prompt for oversized payloads.
  public var contextText: String
  public var createdAt: Date
  public var updatedAt: Date

  public static var databaseTableName: String { "session_launch_context" }

  public init(
    sessionId: String,
    provider: String,
    projectPath: String,
    contextText: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.sessionId = sessionId
    self.provider = provider
    self.projectPath = projectPath
    self.contextText = contextText
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
