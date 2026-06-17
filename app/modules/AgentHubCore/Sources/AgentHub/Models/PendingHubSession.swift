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
  public let launchPath: String?
  public let startedAt: Date
  public let initialPrompt: String?
  public let initialInputText: String?
  public let dangerouslySkipPermissions: Bool
  public let permissionModePlan: Bool
  /// nil = no worktree flag; "" = --worktree (auto-name); non-empty = --worktree <name>
  public let worktreeName: String?

  public init(
    worktree: WorktreeBranch,
    launchPath: String? = nil,
    initialPrompt: String? = nil,
    initialInputText: String? = nil,
    dangerouslySkipPermissions: Bool = false,
    permissionModePlan: Bool = false,
    worktreeName: String? = nil
  ) {
    self.id = UUID()
    self.worktree = worktree
    self.launchPath = launchPath
    self.startedAt = Date()
    self.initialPrompt = initialPrompt
    self.initialInputText = initialInputText
    self.dangerouslySkipPermissions = dangerouslySkipPermissions
    self.permissionModePlan = permissionModePlan
    self.worktreeName = worktreeName
  }

  public var projectPath: String {
    let trimmed = launchPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      return trimmed
    }
    return worktree.path
  }

  /// Creates a placeholder CLISession for use with MonitoringCardView
  public var placeholderSession: CLISession {
    CLISession(
      id: "pending-\(id.uuidString)",
      projectPath: projectPath,
      branchName: worktree.name,
      isWorktree: worktree.isWorktree,
      lastActivityAt: startedAt,
      messageCount: 0,
      isActive: true
    )
  }
}
