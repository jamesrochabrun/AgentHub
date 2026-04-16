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

  @State private var isHovered = false
  @State private var showArchiveConfirm = false
  @State private var pulseScale: CGFloat = 1.0
  @State private var isPulseAnimating = false

  // MARK: - Computed

  private var displayName: String {
    customName ?? session.slug ?? session.shortId
  }

  private var statusColor: Color {
    guard let sessionStatus else { return .secondary }
    switch sessionStatus {
    case .thinking: return .blue
    case .executingTool: return .orange
    case .waitingForUser: return .green
    case .awaitingApproval: return .yellow
    case .idle: return .secondary
    }
  }

  private var isActiveStatus: Bool {
    guard let sessionStatus else { return false }
    switch sessionStatus {
    case .thinking, .executingTool: return true
    default: return false
    }
  }

  private var shouldPulse: Bool { isActiveStatus }

  private func statusDisplayText(_ status: SessionStatus) -> String {
    switch status {
    case .thinking: return "working"
    case .executingTool(let name): return name.lowercased()
    case .waitingForUser: return "ready"
    case .awaitingApproval(let tool): return tool.lowercased()
    case .idle: return "idle"
    }
  }

  private var showActions: Bool {
    isHovered && !isPending && (onArchive != nil || onDeleteWorktree != nil)
  }

  // MARK: - Body

  var body: some View {
    HStack(spacing: 8) {
      // Status dot
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .scaleEffect(shouldPulse ? pulseScale : 1.0)
        .animation(.easeInOut(duration: 0.35), value: statusColor)

      // Content
      VStack(alignment: .leading, spacing: 2) {
        // Row 1: name + provider + status + time
        HStack(spacing: 6) {
          Text(displayName)
            .font(.secondaryDefault)
            .foregroundColor(.primary)
            .lineLimit(1)
            .layoutPriority(1)

          Text(providerKind.rawValue)
            .font(.secondaryCaption)
            .foregroundColor(isPrimary ? .white : .brandPrimary(for: providerKind).opacity(0.8))

          Spacer(minLength: 4)

          statusLabel
            .animation(.easeInOut(duration: 0.3), value: isPending)
            .animation(.easeInOut(duration: 0.3), value: sessionStatus)

          Text(timestamp.timeAgoDisplay())
            .font(.secondaryCaption)
            .foregroundColor(.secondary.opacity(0.7))
        }

        // Row 2: message + actions
        HStack(spacing: 0) {
          if let message = session.firstMessage, !message.isEmpty {
            Text(message)
              .font(.secondarySmall)
              .foregroundColor(.secondary.opacity(0.7))
              .lineLimit(1)
          }

          Spacer(minLength: 4)

          actionsView
            .opacity(showActions ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: showActions)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(rowBackground)
        .animation(.easeInOut(duration: 0.3), value: isPending)
    )
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovered = hovering
      }
      if !hovering && showArchiveConfirm {
        withAnimation(.easeInOut(duration: 0.15)) {
          showArchiveConfirm = false
        }
      }
    }
    .onAppear { startPulseAnimation() }
    .onChange(of: sessionStatus) { _, _ in startPulseAnimation() }
    .onChange(of: isPending) { _, _ in startPulseAnimation() }
  }

  @ViewBuilder
  private var statusLabel: some View {
    if let sessionStatus {
      Text(statusDisplayText(sessionStatus))
        .font(.secondaryCaption)
        .foregroundColor(statusColor)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .id("status-\(statusDisplayText(sessionStatus))")
    } else if isPending {
      Text("starting")
        .font(.secondaryCaption)
        .foregroundColor(.secondary)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .id("status-pending")
    }
  }

  // MARK: - Subviews

  private var rowBackground: Color {
    if isPrimary && isHovered {
      return Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.28 : 0.85)
    }
    if isPrimary {
      return Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.2 : 0.75)
    }
    if isHovered {
      return Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.12 : 0.35)
    }
    return .clear
  }

  @ViewBuilder
  private var actionsView: some View {
    HStack(spacing: 2) {
      if let onArchive {
        if showArchiveConfirm {
          Button {
            showArchiveConfirm = false
            onArchive()
          } label: {
            Text("Confirm")
              .font(.secondaryCaption)
              .foregroundColor(colorScheme == .dark ? .black : .white)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(colorScheme == .dark ? Color.white : Color.black)
              .clipShape(RoundedRectangle(cornerRadius: 4))
          }
          .buttonStyle(.plain)
          .transition(.opacity.combined(with: .scale(scale: 0.8)))
        } else {
          Button {
            withAnimation(.easeInOut(duration: 0.15)) {
              showArchiveConfirm = true
            }
          } label: {
            Image(systemName: "archivebox")
              .font(.system(size: 10))
              .foregroundColor(.secondary)
              .frame(width: 18, height: 18)
          }
          .buttonStyle(.plain)
          .help("Archive session")
        }
      }

      if let onDeleteWorktree {
        if isDeletingWorktree {
          ProgressView()
            .controlSize(.mini)
            .frame(width: 18, height: 18)
        } else {
          Button {
            onDeleteWorktree()
          } label: {
            Image(systemName: "trash")
              .font(.system(size: 10))
              .foregroundColor(.secondary)
              .frame(width: 18, height: 18)
          }
          .buttonStyle(.plain)
          .help("Delete worktree")
        }
      }
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

#Preview("CollapsibleSessionRow — Flat Design") {
  let sessions = [
    CLISession(
      id: "abc12345-6789-0def-ghij-klmnopqrstuv",
      projectPath: "/Users/dev/projects/AgentHub",
      branchName: "feature/multi-session",
      lastActivityAt: Date(),
      messageCount: 12,
      isActive: true,
      firstMessage: "Help me refactor the authentication module to use async/await patterns",
      slug: "cryptic-orbiting-flame"
    ),
    CLISession(
      id: "def98765-4321-0abc-wxyz-abcdefghijkl",
      projectPath: "/Users/dev/projects/AgentHub",
      branchName: "main",
      lastActivityAt: Date().addingTimeInterval(-3600),
      messageCount: 5,
      isActive: true,
      firstMessage: "Write unit tests for the session manager",
      slug: "bright-wandering-star"
    ),
    CLISession(
      id: "fff11111-2222-3333-4444-555566667777",
      projectPath: "/Users/dev/projects/AgentHub",
      branchName: "fix/login-bug",
      lastActivityAt: Date().addingTimeInterval(-86400),
      messageCount: 0,
      isActive: false,
      slug: "silent-morning-dew"
    ),
    CLISession(
      id: "aaa22222-3333-4444-5555-666677778888",
      projectPath: "/Users/dev/projects/AgentHub",
      branchName: "refactor/db-layer",
      lastActivityAt: Date().addingTimeInterval(-7200),
      messageCount: 8,
      isActive: true,
      firstMessage: "Migrate the persistence layer from CoreData to GRDB",
      slug: nil
    ),
  ]

  let statuses: [(SessionStatus?, Bool, Bool)] = [
    (.thinking, false, true),
    (.executingTool(name: "Bash"), false, false),
    (.idle, false, false),
    (.waitingForUser, false, true),
    (.awaitingApproval(tool: "Edit"), false, false),
    (nil, true, false),
  ]

  ScrollView {
    VStack(alignment: .leading, spacing: 24) {

      // --- All states ---
      sectionHeader("All States")
      VStack(spacing: 1) {
        ForEach(Array(statuses.enumerated()), id: \.offset) { idx, state in
          let s = sessions[idx % sessions.count]
          CollapsibleSessionRow(
            session: s,
            providerKind: idx % 2 == 0 ? .claude : .codex,
            timestamp: s.lastActivityAt,
            isPending: state.1,
            isPrimary: state.2,
            customName: idx == 3 ? "Auth Refactor" : nil,
            sessionStatus: state.0,
            colorScheme: .dark,
            onArchive: state.1 ? nil : {},
            onDeleteWorktree: nil,
            onSelect: {}
          )
        }
      }

      Divider().padding(.vertical, 4)

      // --- List feel ---
      sectionHeader("List — multiple sessions")
      VStack(spacing: 1) {
        ForEach(Array(sessions.enumerated()), id: \.1.id) { idx, s in
          CollapsibleSessionRow(
            session: s,
            providerKind: idx < 2 ? .claude : .codex,
            timestamp: s.lastActivityAt,
            isPending: false,
            isPrimary: idx == 0,
            customName: nil,
            sessionStatus: idx == 0 ? .thinking : (idx == 1 ? .executingTool(name: "Read") : .idle),
            colorScheme: .dark,
            onArchive: {},
            onDeleteWorktree: nil,
            onSelect: {}
          )
        }
      }

      Divider().padding(.vertical, 4)

      // --- Light mode ---
      sectionHeader("Light Mode")
      VStack(spacing: 1) {
        CollapsibleSessionRow(
          session: sessions[0],
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

        CollapsibleSessionRow(
          session: sessions[1],
          providerKind: .claude,
          timestamp: Date().addingTimeInterval(-3600),
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

        CollapsibleSessionRow(
          session: sessions[2],
          providerKind: .codex,
          timestamp: Date().addingTimeInterval(-86400),
          isPending: false,
          isPrimary: false,
          customName: nil,
          sessionStatus: .waitingForUser,
          colorScheme: .light,
          onArchive: {},
          onDeleteWorktree: nil,
          onSelect: {}
        )
        .environment(\.colorScheme, .light)
      }
      .background(Color(white: 0.96))
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .padding()
  }
  .frame(width: 340, height: 800)
  .background(Color(nsColor: .windowBackgroundColor))
  .preferredColorScheme(.dark)
}

// MARK: - Preview Helpers

@ViewBuilder
private func sectionHeader(_ title: String) -> some View {
  Text(title)
    .font(.secondaryCaption)
    .foregroundColor(.secondary)
    .textCase(.uppercase)
    .frame(maxWidth: .infinity, alignment: .leading)
}
