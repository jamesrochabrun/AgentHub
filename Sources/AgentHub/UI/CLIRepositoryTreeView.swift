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
  let isSessionMonitored: (String) -> Bool
  let onToggleMonitoring: (CLISession) -> Void
  let onCreateWorktree: () -> Void
  var showLastMessage: Bool = false

  public init(
    repository: SelectedRepository,
    onRemove: @escaping () -> Void,
    onToggleExpanded: @escaping () -> Void,
    onToggleWorktreeExpanded: @escaping (WorktreeBranch) -> Void,
    onConnectSession: @escaping (CLISession) -> Void,
    onCopySessionId: @escaping (CLISession) -> Void,
    isSessionMonitored: @escaping (String) -> Bool,
    onToggleMonitoring: @escaping (CLISession) -> Void,
    onCreateWorktree: @escaping () -> Void,
    showLastMessage: Bool = false
  ) {
    self.repository = repository
    self.onRemove = onRemove
    self.onToggleExpanded = onToggleExpanded
    self.onToggleWorktreeExpanded = onToggleWorktreeExpanded
    self.onConnectSession = onConnectSession
    self.onCopySessionId = onCopySessionId
    self.isSessionMonitored = isSessionMonitored
    self.onToggleMonitoring = onToggleMonitoring
    self.onCreateWorktree = onCreateWorktree
    self.showLastMessage = showLastMessage
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Repository header
      repositoryHeader

      // Worktrees list (when expanded)
      if repository.isExpanded {
        ForEach(repository.worktrees) { worktree in
          CLIWorktreeBranchRow(
            worktree: worktree,
            isExpanded: worktree.isExpanded,
            onToggleExpanded: { onToggleWorktreeExpanded(worktree) },
            onConnectSession: onConnectSession,
            onCopySessionId: onCopySessionId,
            isSessionMonitored: isSessionMonitored,
            onToggleMonitoring: onToggleMonitoring,
            showLastMessage: showLastMessage
          )
          .padding(.leading, 12)
        }
      }
    }
    .background(Color.gray.opacity(0.05))
    .cornerRadius(8)
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
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Spacer()

      // Session count badge
      if repository.totalSessionCount > 0 {
        HStack(spacing: 4) {
          if repository.activeSessionCount > 0 {
            Circle()
              .fill(Color.green)
              .frame(width: 6, height: 6)
          }

          Text("\(repository.totalSessionCount)")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
      }

      // Create worktree button
      Button(action: onCreateWorktree) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption)
          .foregroundColor(.brandPrimary)
      }
      .buttonStyle(.plain)
      .help("Create worktree")

      // Remove button
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
      .help("Remove repository")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
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
      onRemove: { print("Remove") },
      onToggleExpanded: { print("Toggle repo") },
      onToggleWorktreeExpanded: { _ in print("Toggle worktree") },
      onConnectSession: { _ in print("Connect") },
      onCopySessionId: { _ in print("Copy") },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in print("Toggle monitoring") },
      onCreateWorktree: { print("Create worktree") }
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
      onRemove: { print("Remove") },
      onToggleExpanded: { print("Toggle repo") },
      onToggleWorktreeExpanded: { _ in print("Toggle worktree") },
      onConnectSession: { _ in print("Connect") },
      onCopySessionId: { _ in print("Copy") },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in print("Toggle monitoring") },
      onCreateWorktree: { print("Create worktree") }
    )
  }
  .padding()
  .frame(width: 400)
}
