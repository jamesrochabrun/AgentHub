//
//  CLIRepositoryTreeView.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import SwiftUI

// MARK: - CLIRepositoryTreeView

/// Hierarchical tree view for a repository with its worktrees and sessions
public struct CLIRepositoryTreeView: View {
  let repository: SelectedRepository
  let onRemove: () -> Void
  let onToggleExpanded: () -> Void
  let onToggleWorktreeExpanded: (WorktreeBranch) -> Void
  let onConnectSession: (CLISession) -> Void
  let onCopySessionId: (CLISession) -> Void
  let onOpenSessionFile: (CLISession) -> Void
  let isSessionMonitored: (String) -> Bool
  let onToggleMonitoring: (CLISession) -> Void
  let onCreateWorktree: () -> Void
  let onOpenTerminalForWorktree: (WorktreeBranch) -> Void
  let onStartInHubForWorktree: (WorktreeBranch) -> Void
  let onDeleteWorktree: ((WorktreeBranch) -> Void)?
  var showLastMessage: Bool = false
  var isDebugMode: Bool = false
  var deletingWorktreePath: String? = nil

  @State private var worktreeToDelete: WorktreeBranch?
  @State private var showDeleteConfirmation = false

  public init(
    repository: SelectedRepository,
    onRemove: @escaping () -> Void,
    onToggleExpanded: @escaping () -> Void,
    onToggleWorktreeExpanded: @escaping (WorktreeBranch) -> Void,
    onConnectSession: @escaping (CLISession) -> Void,
    onCopySessionId: @escaping (CLISession) -> Void,
    onOpenSessionFile: @escaping (CLISession) -> Void,
    isSessionMonitored: @escaping (String) -> Bool,
    onToggleMonitoring: @escaping (CLISession) -> Void,
    onCreateWorktree: @escaping () -> Void,
    onOpenTerminalForWorktree: @escaping (WorktreeBranch) -> Void,
    onStartInHubForWorktree: @escaping (WorktreeBranch) -> Void,
    onDeleteWorktree: ((WorktreeBranch) -> Void)? = nil,
    showLastMessage: Bool = false,
    isDebugMode: Bool = false,
    deletingWorktreePath: String? = nil
  ) {
    self.repository = repository
    self.onRemove = onRemove
    self.onToggleExpanded = onToggleExpanded
    self.onToggleWorktreeExpanded = onToggleWorktreeExpanded
    self.onConnectSession = onConnectSession
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
    self.isSessionMonitored = isSessionMonitored
    self.onToggleMonitoring = onToggleMonitoring
    self.onCreateWorktree = onCreateWorktree
    self.onOpenTerminalForWorktree = onOpenTerminalForWorktree
    self.onStartInHubForWorktree = onStartInHubForWorktree
    self.onDeleteWorktree = onDeleteWorktree
    self.showLastMessage = showLastMessage
    self.isDebugMode = isDebugMode
    self.deletingWorktreePath = deletingWorktreePath
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Repository header
      repositoryHeader

      // Worktrees list (when expanded)
      if repository.isExpanded {
        ForEach(repository.worktrees) { worktree in
          CLIWorktreeBranchRow(
            worktree: worktree,
            isExpanded: worktree.isExpanded,
            onToggleExpanded: { onToggleWorktreeExpanded(worktree) },
            onOpenTerminal: { onOpenTerminalForWorktree(worktree) },
            onStartInHub: { onStartInHubForWorktree(worktree) },
            onDeleteWorktree: {
              worktreeToDelete = worktree
              showDeleteConfirmation = true
            },
            onConnectSession: onConnectSession,
            onCopySessionId: onCopySessionId,
            onOpenSessionFile: onOpenSessionFile,
            isSessionMonitored: isSessionMonitored,
            onToggleMonitoring: onToggleMonitoring,
            showLastMessage: showLastMessage,
            isDebugMode: isDebugMode,
            isDeleting: worktree.path == deletingWorktreePath
          )
          .padding(.leading, 12)
        }
      }
    }
    .padding(6)
    .agentHubCard(isHighlighted: false)
    .alert("Delete Worktree?", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {
        worktreeToDelete = nil
      }
      Button("Delete", role: .destructive) {
        if let worktree = worktreeToDelete {
          onDeleteWorktree?(worktree)
          worktreeToDelete = nil
        }
      }
    } message: {
      if let worktree = worktreeToDelete {
        Text("Delete worktree at:\n\(worktree.path)\n\nThis action cannot be undone.")
      }
    }
  }

  // MARK: - Repository Header

  private var repositoryHeader: some View {
    HStack(spacing: 8) {
      // Expand/collapse button
      Button(action: onToggleExpanded) {
        HStack(spacing: 8) {
          Image(systemName: repository.isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: 12)

          // Folder icon
          Image(systemName: "folder.fill")
            .font(.subheadline)
            .foregroundColor(.brandPrimary)

          // Repository name (no path - worktree rows show paths)
          Text(repository.name)
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundColor(.primary)

          // Green dot for active sessions (only when collapsed)
          if repository.activeSessionCount > 0 && !repository.isExpanded {
            Circle()
              .fill(Color.green)
              .frame(width: 8, height: 8)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Spacer()

      // Session count badge
      if repository.totalSessionCount > 0 {
        Text("\(repository.totalSessionCount)")
          .font(.caption)
          .foregroundColor(.secondary)
          .agentHubChip(isActive: false)
      }

      // Create worktree button
      Button(action: onCreateWorktree) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption)
          .foregroundColor(.brandPrimary)
          .agentHubChip()
      }
      .buttonStyle(.plain)
      .help("Create worktree")

      // Remove button
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundColor(.secondary)
          .agentHubChip()
      }
      .buttonStyle(.plain)
      .help("Remove repository")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .agentHubRow(isHighlighted: false)
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    CLIRepositoryTreeView(
      repository: SelectedRepository(
        path: "/Users/james/git/ClaudeCodeUI",
        worktrees: [
          WorktreeBranch(
            name: "main",
            path: "/Users/james/git/ClaudeCodeUI",
            isWorktree: false,
            sessions: [
              CLISession(
                id: "abc12345-6789-0def",
                projectPath: "/Users/james/git/ClaudeCodeUI",
                branchName: "main",
                isWorktree: false,
                lastActivityAt: Date(),
                messageCount: 42,
                isActive: true
              )
            ],
            isExpanded: true
          ),
          WorktreeBranch(
            name: "feature/sessions",
            path: "/Users/james/git/ClaudeCodeUI-sessions",
            isWorktree: true,
            sessions: [
              CLISession(
                id: "def67890-1234-5abc",
                projectPath: "/Users/james/git/ClaudeCodeUI-sessions",
                branchName: "feature/sessions",
                isWorktree: true,
                lastActivityAt: Date().addingTimeInterval(-3600),
                messageCount: 15,
                isActive: false
              )
            ],
            isExpanded: false
          )
        ],
        isExpanded: true
      ),
      onRemove: { },
      onToggleExpanded: { },
      onToggleWorktreeExpanded: { _ in },
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      onOpenSessionFile: { _ in },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in },
      onCreateWorktree: { },
      onOpenTerminalForWorktree: { _ in },
      onStartInHubForWorktree: { _ in }
    )

    // Collapsed repository
    CLIRepositoryTreeView(
      repository: SelectedRepository(
        path: "/Users/james/git/AnotherProject",
        worktrees: [
          WorktreeBranch(
            name: "main",
            path: "/Users/james/git/AnotherProject",
            isWorktree: false,
            sessions: []
          )
        ],
        isExpanded: false
      ),
      onRemove: { },
      onToggleExpanded: { },
      onToggleWorktreeExpanded: { _ in },
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      onOpenSessionFile: { _ in },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in },
      onCreateWorktree: { },
      onOpenTerminalForWorktree: { _ in },
      onStartInHubForWorktree: { _ in }
    )
  }
  .padding()
  .frame(width: 400)
}
