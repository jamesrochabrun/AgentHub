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
  let onOpenTerminal: () -> Void
  let onDeleteWorktree: (() -> Void)?
  let onConnectSession: (CLISession) -> Void
  let onCopySessionId: (CLISession) -> Void
  let onOpenSessionFile: (CLISession) -> Void
  let isSessionMonitored: (String) -> Bool
  let onToggleMonitoring: (CLISession) -> Void
  var showLastMessage: Bool = false
  var isDebugMode: Bool = false
  var isDeleting: Bool = false

  // Max visible sessions before scrolling
  private let maxVisibleSessions = 4
  private let sessionRowHeight: CGFloat = 88
  private var maxSessionsHeight: CGFloat {
    CGFloat(maxVisibleSessions) * sessionRowHeight
  }

  /// Sessions sorted with monitored ones at the top, then by last activity
  private var sortedSessions: [CLISession] {
    worktree.sessions.sorted { session1, session2 in
      let isMonitored1 = isSessionMonitored(session1.id)
      let isMonitored2 = isSessionMonitored(session2.id)

      // Monitored sessions first
      if isMonitored1 != isMonitored2 {
        return isMonitored1
      }
      // Then by last activity
      return session1.lastActivityAt > session2.lastActivityAt
    }
  }

  public init(
    worktree: WorktreeBranch,
    isExpanded: Bool,
    onToggleExpanded: @escaping () -> Void,
    onOpenTerminal: @escaping () -> Void,
    onDeleteWorktree: (() -> Void)? = nil,
    onConnectSession: @escaping (CLISession) -> Void,
    onCopySessionId: @escaping (CLISession) -> Void,
    onOpenSessionFile: @escaping (CLISession) -> Void,
    isSessionMonitored: @escaping (String) -> Bool,
    onToggleMonitoring: @escaping (CLISession) -> Void,
    showLastMessage: Bool = false,
    isDebugMode: Bool = false,
    isDeleting: Bool = false
  ) {
    self.worktree = worktree
    self.isExpanded = isExpanded
    self.onToggleExpanded = onToggleExpanded
    self.onOpenTerminal = onOpenTerminal
    self.onDeleteWorktree = onDeleteWorktree
    self.onConnectSession = onConnectSession
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
    self.isSessionMonitored = isSessionMonitored
    self.onToggleMonitoring = onToggleMonitoring
    self.showLastMessage = showLastMessage
    self.isDebugMode = isDebugMode
    self.isDeleting = isDeleting
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

          // Branch icon
          Image(systemName: "arrow.triangle.branch")
            .font(.caption)
            .foregroundColor(worktree.isWorktree ? .brandSecondary : .brandPrimary)

          // Path + [branch] - like git worktree list
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
              Text(worktree.path)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(worktree.isWorktree ? .brandSecondary : .brandPrimary)
                .lineLimit(1)
              Text("[\(worktree.name)]")
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
              Text(worktree.path)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(worktree.isWorktree ? .brandSecondary : .brandPrimary)
                .lineLimit(1)
              Text("[\(worktree.name)]")
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
          }

          Spacer()

          // Delete worktree button (only for actual worktrees in debug mode)
          if isDebugMode && worktree.isWorktree {
            if isDeleting {
              ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
            } else {
              Button(action: { onDeleteWorktree?() }) {
                Image(systemName: "trash")
                  .font(.caption)
                  .foregroundColor(.red.opacity(0.8))
                  .agentHubChip()
              }
              .buttonStyle(.plain)
              .help("Delete worktree")
            }
          }

          // Session count
          if !worktree.sessions.isEmpty {
            Text("\(worktree.sessions.count)")
              .font(.caption)
              .foregroundColor(worktree.activeSessionCount > 0 ? .brandPrimary : .secondary)
              .agentHubChip(isActive: worktree.activeSessionCount > 0)
          }

          // Open terminal button
          Button(action: onOpenTerminal) {
            Image(systemName: "terminal")
              .font(.caption)
              .foregroundColor(.brandSecondary)
              .agentHubChip()
          }
          .buttonStyle(.plain)
          .help("Start Claude in Terminal")
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
          VStack(spacing: 0) {
            ScrollView {
              VStack(spacing: 8) {
                ForEach(sortedSessions) { session in
                  CLISessionRow(
                    session: session,
                    isMonitoring: isSessionMonitored(session.id),
                    onConnect: { onConnectSession(session) },
                    onCopyId: { onCopySessionId(session) },
                    onOpenFile: { onOpenSessionFile(session) },
                    onToggleMonitoring: { onToggleMonitoring(session) },
                    showLastMessage: showLastMessage
                  )
                }
              }
              .padding(.vertical, 4)
            }
            .frame(maxHeight: maxSessionsHeight)

            // Show indicator if there are more sessions
            if worktree.sessions.count > maxVisibleSessions {
              HStack(spacing: 4) {
                Image(systemName: "ellipsis")
                  .font(.caption2)
                Text("\(worktree.sessions.count) sessions")
                  .font(.caption2)
              }
              .foregroundColor(.secondary)
              .padding(.top, 4)
            }
          }
          .padding(.leading, 20)
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
      onOpenTerminal: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      onOpenSessionFile: { _ in },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in }
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
      onOpenTerminal: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      onOpenSessionFile: { _ in },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in }
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
      onOpenTerminal: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      onOpenSessionFile: { _ in },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in }
    )
  }
  .padding()
  .frame(width: 350)
}
