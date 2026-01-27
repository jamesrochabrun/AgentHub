//
//  SessionRepoMapping.swift
//  AgentHub
//
//  Maps sessions to their parent repository to prevent collision
//  when worktree paths are reused across different repositories.
//

import Foundation
import GRDB

/// Maps a session to its parent repository.
/// This prevents sessions from incorrectly appearing under a new worktree
/// when the same path and branch name are reused by a different repository.
public struct SessionRepoMapping: Codable, Sendable, FetchableRecord, PersistableRecord {

  /// The session UUID (primary key)
  public var sessionId: String

  /// The parent repository path this session belongs to
  public var parentRepoPath: String

  /// The worktree path where the session ran
  public var worktreePath: String

  /// When this mapping was created
  public var assignedAt: Date

  // MARK: - GRDB Configuration

  public static var databaseTableName: String { "session_repo_mapping" }

  // MARK: - Initialization

  public init(
    sessionId: String,
    parentRepoPath: String,
    worktreePath: String,
    assignedAt: Date = Date()
  ) {
    self.sessionId = sessionId
    self.parentRepoPath = parentRepoPath
    self.worktreePath = worktreePath
    self.assignedAt = assignedAt
  }
}
