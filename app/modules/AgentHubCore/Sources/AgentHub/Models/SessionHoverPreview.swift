//
//  SessionHoverPreview.swift
//  AgentHub
//

import Foundation

// MARK: - SessionHoverPreview

/// Snapshot of the metadata shown in the hover popup for a sidebar session row.
/// Built from data the row already has — the session plus the selected
/// repositories — so the popup never triggers extra I/O.
public struct SessionHoverPreview: Equatable, Sendable {
  /// Custom name, slug, or short ID — in that order of preference.
  public let sessionName: String
  public let firstMessage: String?
  /// Parent repository name (the registered repo root, even for worktrees).
  public let repositoryName: String
  public let branchName: String?
  /// Registered worktree root path, only when the session runs in a worktree.
  public let worktreePath: String?

  public init(
    sessionName: String,
    firstMessage: String?,
    repositoryName: String,
    branchName: String?,
    worktreePath: String?
  ) {
    self.sessionName = sessionName
    self.firstMessage = firstMessage
    self.repositoryName = repositoryName
    self.branchName = branchName
    self.worktreePath = worktreePath
  }

  /// Resolves preview fields for a session. Worktree sessions map back to
  /// their registered worktree root and parent repository via
  /// `WorktreeModuleResolver.bestMatch`, so nested launch paths still resolve
  /// to the right module. Falls back to path-derived names when the session's
  /// repository is not (or no longer) selected.
  public static func make(
    session: CLISession,
    customName: String?,
    repositories: [SelectedRepository]
  ) -> SessionHoverPreview {
    let match = WorktreeModuleResolver.bestMatch(
      for: session.projectPath,
      repositories: repositories
    )

    let isWorktree = match.map(\.worktree.isWorktree) ?? session.isWorktree
    let worktreePath: String? = if isWorktree {
      match?.worktree.path ?? session.projectPath
    } else {
      nil
    }

    let branchName = session.branchName
      ?? (isWorktree ? match?.worktree.name : nil)

    let trimmedFirstMessage = session.firstMessage?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return SessionHoverPreview(
      sessionName: customName ?? session.displayName,
      firstMessage: (trimmedFirstMessage?.isEmpty ?? true) ? nil : trimmedFirstMessage,
      repositoryName: match?.repository.name ?? session.projectName,
      branchName: branchName,
      worktreePath: worktreePath
    )
  }

  /// Worktree path with the home directory abbreviated for display.
  public func displayWorktreePath(homeDirectory: String = NSHomeDirectory()) -> String? {
    guard let worktreePath else { return nil }
    let normalizedHome = WorktreeModuleResolver.normalizedDirectoryPath(homeDirectory)
    guard worktreePath == normalizedHome || worktreePath.hasPrefix(normalizedHome + "/") else {
      return worktreePath
    }
    return "~" + worktreePath.dropFirst(normalizedHome.count)
  }
}
