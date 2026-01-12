//
//  CLIWorktreeBranchRow.swift
//  AgentHub
//
//  Created by Assistant on 1/10/26.
//

import SwiftUI

// MARK: - CLIWorktreeBranchRow

/// Row displaying a worktree path with its current branch and sessions
/// Mirrors `git worktree list` output: path [branch] [count]
public struct CLIWorktreeBranchRow: View {
  let worktree: WorktreeBranch
  let isExpanded: Bool
  let onToggleExpanded: () -> Void
  let onConnectSession: (CLISession) -> Void
  let onCopySessionId: (CLISession) -> Void
  var fileWatcher: SessionFileWatcher?
  var showLastMessage: Bool = false

  public init(
    worktree: WorktreeBranch,
    isExpanded: Bool,
    onToggleExpanded: @escaping () -> Void,
    onConnectSession: @escaping (CLISession) -> Void,
    onCopySessionId: @escaping (CLISession) -> Void,
    fileWatcher: SessionFileWatcher? = nil,
    showLastMessage: Bool = false
  ) {
    self.worktree = worktree
    self.isExpanded = isExpanded
    self.onToggleExpanded = onToggleExpanded
    self.onConnectSession = onConnectSession
    self.onCopySessionId = onCopySessionId
    self.fileWatcher = fileWatcher
    self.showLastMessage = showLastMessage
  }

  /// Truncates a path from the middle if too long
  private func truncatedPath(_ path: String, maxLength: Int = 45) -> String {
    guard path.count > maxLength else { return path }

    let components = path.split(separator: "/").map(String.init)
    guard components.count > 4 else { return path }

    // Keep first component (Users) and last 2 components
    let prefix = "/" + components.prefix(1).joined(separator: "/")
    let suffix = components.suffix(2).joined(separator: "/")

    return "\(prefix)/.../\(suffix)"
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Worktree header - shows path [branch] like git worktree list
      Button(action: onToggleExpanded) {
        HStack(spacing: 8) {
          // Expand/collapse indicator
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(width: 12)

          // Branch icon (same icon for both, different colors)
          Image(systemName: "arrow.triangle.branch")
            .font(.caption)
            .foregroundColor(worktree.isWorktree ? .brandSecondary : .brandPrimary)

          // Path + [branch] - like git worktree list
          HStack(spacing: 4) {
            // Path (truncated if needed)
            Text(truncatedPath(worktree.path))
              .font(.caption)
              .foregroundColor(worktree.isWorktree ? .brandSecondary : .brandPrimary)
              .lineLimit(1)

            // Branch name in brackets
            Text("[\(worktree.name)]")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          Spacer()

          // Session count
          if !worktree.sessions.isEmpty {
            Text("\(worktree.sessions.count)")
              .font(.caption)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(worktree.activeSessionCount > 0 ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
              .foregroundColor(worktree.activeSessionCount > 0 ? .green : .secondary)
              .cornerRadius(4)
          }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      // Sessions list (when expanded)
      if isExpanded {
        if worktree.sessions.isEmpty {
          Text("No sessions")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.leading, 32)
            .padding(.vertical, 4)
        } else {
          ForEach(worktree.sessions) { session in
            CLISessionRow(
              session: session,
              onConnect: { onConnectSession(session) },
              onCopyId: { onCopySessionId(session) },
              fileWatcher: fileWatcher,
              showLastMessage: showLastMessage
            )
            .padding(.leading, 20)
          }
        }
      }
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 16) {
    // Expanded worktree with sessions
    CLIWorktreeBranchRow(
      worktree: WorktreeBranch(
        name: "feature/sessions",
        path: "/Users/james/git/Project-feature",
        isWorktree: true,
        sessions: [
          CLISession(
            id: "abc12345-6789-0def",
            projectPath: "/Users/james/git/Project-feature",
            branchName: "feature/sessions",
            isWorktree: true,
            lastActivityAt: Date(),
            messageCount: 42,
            isActive: true
          )
        ]
      ),
      isExpanded: true,
      onToggleExpanded: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      fileWatcher: nil
    )

    Divider()

    // Collapsed main branch
    CLIWorktreeBranchRow(
      worktree: WorktreeBranch(
        name: "main",
        path: "/Users/james/git/Project",
        isWorktree: false,
        sessions: [
          CLISession(
            id: "def67890-1234-5abc",
            projectPath: "/Users/james/git/Project",
            branchName: "main",
            isWorktree: false,
            lastActivityAt: Date().addingTimeInterval(-3600),
            messageCount: 15,
            isActive: false
          )
        ]
      ),
      isExpanded: false,
      onToggleExpanded: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      fileWatcher: nil
    )

    Divider()

    // Empty branch
    CLIWorktreeBranchRow(
      worktree: WorktreeBranch(
        name: "bugfix/issue-123",
        path: "/Users/james/git/Project-bugfix",
        isWorktree: true,
        sessions: []
      ),
      isExpanded: true,
      onToggleExpanded: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      fileWatcher: nil
    )
  }
  .padding()
  .frame(width: 350)
}
