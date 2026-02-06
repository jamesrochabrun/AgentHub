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
  let providerKind: SessionProviderKind
  let onToggleExpanded: () -> Void
  let onOpenTerminal: () -> Void
  let onOpenTerminalDangerous: () -> Void
  let onStartInHub: () -> Void
  let onStartInHubDangerous: () -> Void
  let onDeleteWorktree: (() -> Void)?
  let onConnectSession: (CLISession) -> Void
  let onCopySessionId: (CLISession) -> Void
  let onOpenSessionFile: (CLISession) -> Void
  let isSessionMonitored: (String) -> Bool
  let onToggleMonitoring: (CLISession) -> Void
  let onArchiveSession: (CLISession) -> Void
  let onDeleteSession: (CLISession) -> Void
  let getCustomName: ((String) -> String?)?
  var showLastMessage: Bool = false
  var isDebugMode: Bool = false
  var isDeleting: Bool = false

  @State private var visibleSessionCount: Int = 5
  @State private var showNewSessionMenu: Bool = false

  // Initial visible sessions and load increment
  private let initialVisibleSessions = 5
  private let loadMoreIncrement = 10

  /// Sessions sorted by last activity
  private var sortedSessions: [CLISession] {
    worktree.sessions.sorted { session1, session2 in
      // Disabled: Monitored sessions first
      // let isMonitored1 = isSessionMonitored(session1.id)
      // let isMonitored2 = isSessionMonitored(session2.id)
      // if isMonitored1 != isMonitored2 {
      //   return isMonitored1
      // }

      // Sort by last activity only
      return session1.lastActivityAt > session2.lastActivityAt
    }
  }

  private var visibleSessions: ArraySlice<CLISession> {
    sortedSessions.prefix(visibleSessionCount)
  }

  private var remainingSessions: Int {
    max(0, sortedSessions.count - visibleSessionCount)
  }

  private var hasMoreSessions: Bool {
    remainingSessions > 0
  }

  private var providerLabel: String {
    providerKind.rawValue
  }

  private var supportsExternalTerminal: Bool {
    providerKind == .claude
  }

  private var supportsDangerousMode: Bool {
    providerKind == .claude
  }

  public init(
    worktree: WorktreeBranch,
    isExpanded: Bool,
    providerKind: SessionProviderKind = .claude,
    onToggleExpanded: @escaping () -> Void,
    onOpenTerminal: @escaping () -> Void,
    onOpenTerminalDangerous: @escaping () -> Void = {},
    onStartInHub: @escaping () -> Void,
    onStartInHubDangerous: @escaping () -> Void = {},
    onDeleteWorktree: (() -> Void)? = nil,
    onConnectSession: @escaping (CLISession) -> Void,
    onCopySessionId: @escaping (CLISession) -> Void,
    onOpenSessionFile: @escaping (CLISession) -> Void,
    isSessionMonitored: @escaping (String) -> Bool,
    onToggleMonitoring: @escaping (CLISession) -> Void,
    onArchiveSession: @escaping (CLISession) -> Void,
    onDeleteSession: @escaping (CLISession) -> Void,
    getCustomName: ((String) -> String?)? = nil,
    showLastMessage: Bool = false,
    isDebugMode: Bool = false,
    isDeleting: Bool = false
  ) {
    self.worktree = worktree
    self.isExpanded = isExpanded
    self.providerKind = providerKind
    self.onToggleExpanded = onToggleExpanded
    self.onOpenTerminal = onOpenTerminal
    self.onOpenTerminalDangerous = onOpenTerminalDangerous
    self.onStartInHub = onStartInHub
    self.onStartInHubDangerous = onStartInHubDangerous
    self.onDeleteWorktree = onDeleteWorktree
    self.onConnectSession = onConnectSession
    self.onCopySessionId = onCopySessionId
    self.onOpenSessionFile = onOpenSessionFile
    self.isSessionMonitored = isSessionMonitored
    self.onToggleMonitoring = onToggleMonitoring
    self.onArchiveSession = onArchiveSession
    self.onDeleteSession = onDeleteSession
    self.getCustomName = getCustomName
    self.showLastMessage = showLastMessage
    self.isDebugMode = isDebugMode
    self.isDeleting = isDeleting
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Worktree header - flat single line: > Y path  branch  count ●  🗑  +
      Button(action: onToggleExpanded) {
        HStack(spacing: 8) {
          // Expand/collapse indicator
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundColor(.secondary)
            .frame(width: 12)

          // Branch icon
          Image(systemName: "arrow.triangle.branch")
            .font(.subheadline)
            .foregroundColor(.primary)

          // Path
          Text(worktree.path)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)

          // Branch name
          Text(worktree.name)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.primary)
            .lineLimit(1)

          Spacer()

          // Session count with active indicator
          if !worktree.sessions.isEmpty {
            HStack(spacing: 4) {
              Text("\(worktree.sessions.count)")
                .font(.caption)
                .foregroundColor(.secondary)

              if worktree.activeSessionCount > 0 {
                Circle()
                  .fill(Color.green)
                  .frame(width: 6, height: 6)
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
          }

          // Delete worktree button (only for actual worktrees)
          if worktree.isWorktree {
            if isDeleting {
              ProgressView()
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
            } else {
              Button(action: { onDeleteWorktree?() }) {
                Image(systemName: "trash")
                  .font(.caption)
                  .foregroundColor(.primary.opacity(0.8))
                  .frame(width: 24, height: 24)
                  .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                      .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                  )
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help("Delete worktree")
            }
          }

          // New session button with menu
          Button(action: { showNewSessionMenu.toggle() }) {
            Image(systemName: "plus")
              .font(.caption)
              .foregroundColor(.primary)
              .frame(width: 24, height: 24)
              .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
              )
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Start new \(providerLabel) session")
          .popover(isPresented: $showNewSessionMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
              // Start in Hub (Recommended)
              Button(action: {
                showNewSessionMenu = false
                onStartInHub()
              }) {
                Label("Start in Hub (Recommended)", systemImage: "square.grid.2x2")
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .foregroundColor(.primary)
              }
              .buttonStyle(.plain)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .contentShape(Rectangle())

              if supportsDangerousMode {
                // Start in Hub (Dangerously)
                Button(action: {
                  showNewSessionMenu = false
                  onStartInHubDangerous()
                }) {
                  Label("Start in Hub (Dangerously)", systemImage: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
              }

              if supportsExternalTerminal {
                Divider()

                // Open in Terminal
                Button(action: {
                  showNewSessionMenu = false
                  onOpenTerminal()
                }) {
                  Label("Open in Terminal", systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
              }
            }
            .padding(.vertical, 8)
            .frame(width: 260)
          }
        }
        .padding(.vertical, 14)
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
          ScrollView {
            VStack(spacing: 4) {
              ForEach(visibleSessions) { session in
                CLISessionRow(
                  session: session,
                  customName: getCustomName?(session.id),
                  providerKind: providerKind,
                  isMonitoring: isSessionMonitored(session.id),
                  onConnect: { onConnectSession(session) },
                  onCopyId: { onCopySessionId(session) },
                  onOpenFile: { onOpenSessionFile(session) },
                  onToggleMonitoring: { onToggleMonitoring(session) },
                  onArchive: { onArchiveSession(session) },
                  onDelete: { onDeleteSession(session) },
                  showLastMessage: showLastMessage
                )
              }

              // Show "...X more" button if there are more sessions
              if hasMoreSessions {
                Button {
                  visibleSessionCount += loadMoreIncrement
                } label: {
                  HStack(spacing: 4) {
                    Image(systemName: "ellipsis")
                      .font(.caption2)
                    Text("\(remainingSessions) more")
                      .font(.caption2)
                  }
                  .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
              }
            }
          }
          .frame(maxHeight: 300)
          .padding(.top, 4)
          .padding(.bottom, 4)
        }
      }
    }
    .onChange(of: isExpanded) { _, newValue in
      if newValue {
        visibleSessionCount = initialVisibleSessions
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
      onStartInHub: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      onOpenSessionFile: { _ in },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in },
      onArchiveSession: { _ in },
      onDeleteSession: { _ in }
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
      onStartInHub: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      onOpenSessionFile: { _ in },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in },
      onArchiveSession: { _ in },
      onDeleteSession: { _ in }
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
      onStartInHub: {},
      onConnectSession: { _ in },
      onCopySessionId: { _ in },
      onOpenSessionFile: { _ in },
      isSessionMonitored: { _ in false },
      onToggleMonitoring: { _ in },
      onArchiveSession: { _ in },
      onDeleteSession: { _ in }
    )
  }
  .padding()
  .frame(width: 350)
}
