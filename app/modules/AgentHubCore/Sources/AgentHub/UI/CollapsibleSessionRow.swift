import SwiftUI

// MARK: - CollapsibleSessionRow

struct CollapsibleSessionRow: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  let timestamp: Date
  let isPending: Bool
  let isPrimary: Bool
  let customName: String?
  let sessionStatus: SessionStatus?
  let colorScheme: ColorScheme
  let onArchive: (() -> Void)?
  let onDeleteWorktree: (() -> Void)?
  var isDeletingWorktree: Bool = false
  let onSelect: () -> Void

  @State private var gradientProgress: CGFloat = 0
  @State private var showArchiveConfirm = false
  @State private var pulseScale: CGFloat = 1.0
  @State private var isPulseAnimating = false

  private var tildeProjectPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if session.projectPath.hasPrefix(home) {
      return "~" + session.projectPath.dropFirst(home.count)
    }
    return session.projectPath
  }

  private var statusColor: Color {
    guard let sessionStatus else { return .brandPrimary(for: providerKind) }
    switch sessionStatus {
    case .thinking: return .blue
    case .executingTool: return .orange
    case .waitingForUser: return .green
    case .awaitingApproval: return .yellow
    case .idle: return .gray
    }
  }

  private var isActiveStatus: Bool {
    guard let sessionStatus else { return false }
    switch sessionStatus {
    case .thinking, .executingTool: return true
    default: return false
    }
  }

  private var statusIcon: String? {
    guard let sessionStatus else { return nil }
    switch sessionStatus {
    case .thinking: return nil  // Use pulsing dot
    case .executingTool: return nil  // Use pulsing dot
    case .waitingForUser: return "checkmark.circle.fill"
    case .awaitingApproval: return "exclamationmark.circle.fill"
    case .idle: return nil
    }
  }

  private var shouldPulse: Bool {
    isActiveStatus
  }

  private func statusDisplayText(_ status: SessionStatus) -> String {
    switch status {
    case .thinking: return "Working"
    case .executingTool(let name): return name
    case .waitingForUser: return "Ready"
    case .awaitingApproval(let tool): return "Approval: \(tool)"
    case .idle: return "Idle"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      // Top row: icon + session ID + status badge
      HStack(alignment: .top, spacing: 6) {
        // Terminal prompt icon
        Text(">_")
          .font(.jetBrainsMono(size: 13, weight: .bold))
          .foregroundColor(statusColor.opacity(isActiveStatus ? 1.0 : 0.5))

        // Session ID
        HStack(spacing: 4) {
          Text("session:")
            .font(.primaryCaption)
            .foregroundColor(.secondary)
          Text(customName ?? session.slug ?? session.shortId)
            .font(.jetBrainsMono(size: 13, weight: .bold))
            .lineLimit(1)
        }

        Spacer(minLength: 4)

        // Status badge
        VStack(alignment: .trailing, spacing: 4) {
        // Status badge
        if let sessionStatus {
          HStack(spacing: 4) {
            Circle()
              .fill(statusColor)
              .frame(width: 6, height: 6)
              .scaleEffect(shouldPulse ? pulseScale : 1.0)
            Text(statusDisplayText(sessionStatus).lowercased())
              .font(.primaryCaption)
              .foregroundColor(statusColor)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(statusColor.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if isPending {
          Text("starting")
            .font(.primaryCaption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }

          // Timestamp
          Text(timestamp.timeAgoDisplay())
            .font(.secondaryCaption)
            .foregroundColor(.secondary)
        }
      }

      // Branch line (aligned to leading edge)
      if let branch = session.branchName {
        HStack(spacing: 4) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 9))
            .foregroundColor(.secondary.opacity(0.6))
          Text(branch)
            .font(.primaryCaption)
            .foregroundColor(.secondary.opacity(0.9))
            .lineLimit(1)
        }
      }

      // Message preview with $ prompt (aligned to leading edge)
      if let message = session.firstMessage, !message.isEmpty {
        Text("$ " + (message.count > 60 ? String(message.prefix(60)) + "..." : message))
          .font(.primarySmall)
          .foregroundColor(.primary.opacity(0.5))
          .lineLimit(1)
          .padding(.top, 2)
          .padding(.trailing, 36)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .foregroundColor(.primary)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: 6)
          .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.94))
        RoundedRectangle(cornerRadius: 6)
          .fill(LinearGradient(
            colors: [
              Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.2 : 0.1),
              Color.clear
            ],
            startPoint: .leading,
            endPoint: .trailing
          ))
          .opacity(gradientProgress)
      }
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(
          isPrimary
            ? statusColor.opacity(0.3)
            : Color.clear,
          lineWidth: 1
        )
    )
    .overlay(alignment: .bottomTrailing) {
      if !isPending, (onArchive != nil || onDeleteWorktree != nil) {
        HStack(spacing: 4) {
          if let onArchive {
            Group {
              if showArchiveConfirm {
                Button {
                  showArchiveConfirm = false
                  onArchive()
                } label: {
                  Text("Confirm")
                    .font(.secondaryCaption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.brandPrimary(for: providerKind))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
              } else {
                Button {
                  withAnimation(.easeInOut(duration: 0.15)) {
                    showArchiveConfirm = true
                  }
                } label: {
                  Image(systemName: "archivebox")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Archive session")
              }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
          }

          if let onDeleteWorktree {
            if isDeletingWorktree {
              ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
            } else {
              Button {
                onDeleteWorktree()
              } label: {
                Image(systemName: "trash")
                  .font(.system(size: 11))
                  .foregroundColor(.secondary)
                  .frame(width: 20, height: 20)
              }
              .buttonStyle(.plain)
              .help("Delete worktree")
            }
          }
        }
        .padding(.trailing, 8)
        .padding(.bottom, 8)
      }
    }
    .padding(.vertical, 2)
    .onHover { hovering in
      if !hovering && showArchiveConfirm {
        withAnimation(.easeInOut(duration: 0.15)) {
          showArchiveConfirm = false
        }
      }
    }
    .onAppear {
      gradientProgress = isPrimary ? 1 : 0
      startPulseAnimation()
    }
    .onChange(of: isPrimary) { _, newValue in
      withAnimation(.interpolatingSpring(mass: 0.8, stiffness: 350, damping: 22, initialVelocity: 0)) {
        gradientProgress = newValue ? 1 : 0
      }
    }
    .onChange(of: sessionStatus) { _, _ in
      startPulseAnimation()
    }
  }

  // MARK: - Animations

  private func startPulseAnimation() {
    guard shouldPulse else {
      guard isPulseAnimating else { return }
      isPulseAnimating = false
      withAnimation(.easeOut(duration: 0.2)) {
        pulseScale = 1.0
      }
      return
    }

    guard !isPulseAnimating else { return }
    isPulseAnimating = true
    pulseScale = 1.0

    withAnimation(
      .easeInOut(duration: 1.0)
      .repeatForever(autoreverses: true)
    ) {
      pulseScale = 1.4
    }
  }
}

// MARK: - Preview

#Preview("CollapsibleSessionRow States") {
  let claudeSession = CLISession(
    id: "abc12345-6789-0def-ghij-klmnopqrstuv",
    projectPath: "/Users/dev/projects/AgentHub",
    branchName: "feature/multi-session",
    lastActivityAt: Date(),
    messageCount: 12,
    isActive: true,
    firstMessage: "Help me refactor the authentication module to use async/await patterns",
    slug: "cryptic-orbiting-flame"
  )

  let codexSession = CLISession(
    id: "def98765-4321-0abc-wxyz-abcdefghijkl",
    projectPath: "/Users/dev/projects/AgentHub",
    branchName: "main",
    lastActivityAt: Date().addingTimeInterval(-3600),
    messageCount: 5,
    isActive: true,
    firstMessage: "Write unit tests for the session manager",
    slug: "bright-wandering-star"
  )

  let pendingSession = CLISession(
    id: "fff11111-2222-3333-4444-555566667777",
    projectPath: "/Users/dev/projects/AgentHub",
    branchName: "fix/login-bug",
    lastActivityAt: Date(),
    messageCount: 0,
    isActive: false,
    slug: "silent-morning-dew"
  )

  ScrollView {
    VStack(spacing: 16) {
      // Section: Claude provider
      Text("Claude — Selected (isPrimary)")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: claudeSession,
        providerKind: .claude,
        timestamp: Date(),
        isPending: false,
        isPrimary: true,
        customName: nil,
        sessionStatus: .thinking,
        colorScheme: .dark,
        onArchive: {},
        onDeleteWorktree: nil,
        onSelect: {}
      )

      Text("Claude — Default")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: claudeSession,
        providerKind: .claude,
        timestamp: Date(),
        isPending: false,
        isPrimary: false,
        customName: nil,
        sessionStatus: .idle,
        colorScheme: .dark,
        onArchive: {},
        onDeleteWorktree: nil,
        onSelect: {}
      )

      Divider().padding(.vertical, 4)

      // Section: Codex provider
      Text("Codex — Selected (isPrimary)")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: codexSession,
        providerKind: .codex,
        timestamp: Date().addingTimeInterval(-3600),
        isPending: false,
        isPrimary: true,
        customName: nil,
        sessionStatus: .executingTool(name: "Bash"),
        colorScheme: .dark,
        onArchive: {},
        onDeleteWorktree: nil,
        onSelect: {}
      )

      Text("Codex — Default")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: codexSession,
        providerKind: .codex,
        timestamp: Date().addingTimeInterval(-3600),
        isPending: false,
        isPrimary: false,
        customName: nil,
        sessionStatus: .waitingForUser,
        colorScheme: .dark,
        onArchive: {},
        onDeleteWorktree: nil,
        onSelect: {}
      )

      Divider().padding(.vertical, 4)

      // Section: Pending state
      Text("Claude — Pending + Selected")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: pendingSession,
        providerKind: .claude,
        timestamp: Date(),
        isPending: true,
        isPrimary: true,
        customName: nil,
        sessionStatus: nil,
        colorScheme: .dark,
        onArchive: nil,
        onDeleteWorktree: nil,
        onSelect: {}
      )

      Text("Codex — Pending + Default")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: pendingSession,
        providerKind: .codex,
        timestamp: Date(),
        isPending: true,
        isPrimary: false,
        customName: nil,
        sessionStatus: nil,
        colorScheme: .dark,
        onArchive: nil,
        onDeleteWorktree: nil,
        onSelect: {}
      )

      Divider().padding(.vertical, 4)

      // Section: Custom name
      Text("Claude — Custom Name + Selected")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: claudeSession,
        providerKind: .claude,
        timestamp: Date(),
        isPending: false,
        isPrimary: true,
        customName: "Auth Refactor",
        sessionStatus: .awaitingApproval(tool: "Edit"),
        colorScheme: .dark,
        onArchive: {},
        onDeleteWorktree: nil,
        onSelect: {}
      )

      Divider().padding(.vertical, 4)

      // Section: Light mode
      Text("Claude — Selected (Light Mode)")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: claudeSession,
        providerKind: .claude,
        timestamp: Date(),
        isPending: false,
        isPrimary: true,
        customName: nil,
        sessionStatus: .thinking,
        colorScheme: .light,
        onArchive: {},
        onDeleteWorktree: nil,
        onSelect: {}
      )
      .environment(\.colorScheme, .light)

      Text("Claude — Default (Light Mode)")
        .font(.caption).foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      CollapsibleSessionRow(
        session: claudeSession,
        providerKind: .claude,
        timestamp: Date(),
        isPending: false,
        isPrimary: false,
        customName: nil,
        sessionStatus: .idle,
        colorScheme: .light,
        onArchive: {},
        onDeleteWorktree: nil,
        onSelect: {}
      )
      .environment(\.colorScheme, .light)
    }
    .padding()
  }
  .frame(width: 320, height: 900)
  .background(Color(nsColor: .windowBackgroundColor))
  .preferredColorScheme(.dark)
}
