//
//  PendingHubSession.swift
//  AgentHub
//
//  Created by Assistant on 1/20/26.
//

import Foundation

/// A session being started in the Hub's embedded terminal (no session ID yet)
/// Used when user clicks "Start in Hub" to track the pending session until Claude creates the session file
public struct PendingHubSession: Identifiable {
  public let id: UUID
  public let worktree: WorktreeBranch
  public let startedAt: Date

  public init(worktree: WorktreeBranch) {
    self.id = UUID()
    self.worktree = worktree
    self.startedAt = Date()
  }

  /// Creates a placeholder CLISession for use with MonitoringCardView
  public var placeholderSession: CLISession {
    CLISession(
      id: "pending-\(id.uuidString)",
      projectPath: worktree.path,
      branchName: worktree.name,
      isWorktree: worktree.isWorktree,
      lastActivityAt: startedAt,
      messageCount: 0,
      isActive: true
    )
  }
}
