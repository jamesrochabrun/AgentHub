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
  let getCustomName: ((String) -> String?)?
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
    getCustomName: ((String) -> String?)? = nil,
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
    self.getCustomName = getCustomName
    self.showLastMessage = showLastMessage
    self.isDebugMode = isDebugMode
    self.deletingWorktreePath = deletingWorktreePath
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Repository header
      repositoryHeader

      // Worktrees list (when expanded)
      if repository.isExpanded {
        ForEach(Array(repository.worktrees.enumerated()), id: \.element.id) { index, worktree in
          // Divider before each worktree row
          Divider()



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
            getCustomName: getCustomName,
            showLastMessage: showLastMessage,
            isDebugMode: isDebugMode,
            isDeleting: worktree.path == deletingWorktreePath
          )
        }
      }
    }
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
            .foregroundColor(.secondary)

          // Repository name
          Text(repository.name)
            .font(.headline)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Spacer()

      // Session count
      if repository.totalSessionCount > 0 {
        Text("\(repository.totalSessionCount)")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
          )
      }

      // Create worktree button
      Button(action: onCreateWorktree) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption)
          .foregroundColor(.brandSecondary)
          .padding(6)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
      .help("Create worktree")

      // Remove button
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundColor(.secondary)
          .padding(6)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
      .help("Remove repository")
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 8)
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
