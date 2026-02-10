import SwiftUI

// MARK: - CollapsibleSessionRow

struct CollapsibleSessionRow: View {
  let session: CLISession
  let providerKind: SessionProviderKind
  let timestamp: Date
  let isPending: Bool
  let isPrimary: Bool
  let customName: String?
  let colorScheme: ColorScheme
  let onArchive: (() -> Void)?
  let onSelect: () -> Void

  @State private var gradientProgress: CGFloat = 0
  @State private var showArchiveConfirm = false

  private var tildeProjectPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if session.projectPath.hasPrefix(home) {
      return "~" + session.projectPath.dropFirst(home.count)
    }
    return session.projectPath
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Path + branch header bar
      HStack(spacing: 5) {
        Image(systemName: "folder")
          .font(.system(size: 9))
          .foregroundColor(.secondary.opacity(0.6))

        Text(tildeProjectPath)
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(.secondary.opacity(0.9))
          .lineLimit(1)
          .truncationMode(.middle)

        if let branch = session.branchName {
          Spacer(minLength: 4)

          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 9))
            .foregroundColor(.secondary.opacity(0.6))

          Text(branch)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary.opacity(0.9))
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        ZStack {
          UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 6)
            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
          UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 6)
            .fill(LinearGradient(
              colors: [
                Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.45 : 0.35),
                colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
              ],
              startPoint: .trailing,
              endPoint: .leading
            ))
            .mask(
              GeometryReader { geo in
                Rectangle()
                  .frame(width: geo.size.width * gradientProgress)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            )
        }
      )

      // Content area
      VStack(alignment: .leading, spacing: 8) {
        // Session name + provider
        HStack {
        Text(customName ?? session.slug  ?? "Session: \(session.shortId)")
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)

          if isPending {
            Text("Starting")
              .font(.system(size: 9))
              .foregroundColor(.secondary)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.12))
              .clipShape(RoundedRectangle(cornerRadius: 3))
          }

          Spacer()

          Text(providerKind.rawValue)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.brandPrimary(for: providerKind))
        }

        // Dot + timestamp
        HStack(spacing: 5) {
          Circle()
            .fill(Color.brandPrimary(for: providerKind))
            .frame(width: 6, height: 6)

          Text(timestamp.timeAgoDisplay())
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }

        // First message preview
        if let message = session.firstMessage, !message.isEmpty {
          Text(message.prefix(80) + (message.count > 80 ? "..." : ""))
            .font(.system(size: 11))
            .foregroundColor(.primary.opacity(0.7))
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 10)
    }
    .foregroundColor(.primary)
    .contentShape(Rectangle())
    .onTapGesture { onSelect() }
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: 8)
          .fill(colorScheme == .dark ? Color.secondary.opacity(0.12) : Color.black.opacity(0.03))
        RoundedRectangle(cornerRadius: 8)
          .fill(LinearGradient(
            colors: [
              Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.25 : 0.15),
              colorScheme == .dark ? Color.secondary.opacity(0.12) : Color.black.opacity(0.03)
            ],
            startPoint: .trailing,
            endPoint: .leading
          ))
          .mask(
            GeometryReader { geo in
              Rectangle()
                .frame(width: geo.size.width * gradientProgress)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          )
      }
    )
    .overlay(alignment: .bottomTrailing) {
      if !isPending, let onArchive {
        Group {
          if showArchiveConfirm {
            Button {
              showArchiveConfirm = false
              onArchive()
            } label: {
              Text("Confirm")
                .font(.system(size: 10, weight: .semibold))
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
        .padding(.trailing, 8)
        .padding(.bottom, 8)
      }
    }
    .padding(.vertical, 8)
    .onHover { hovering in
      if !hovering && showArchiveConfirm {
        withAnimation(.easeInOut(duration: 0.15)) {
          showArchiveConfirm = false
        }
      }
    }
    .onAppear {
      gradientProgress = isPrimary ? 1 : 0
    }
    .onChange(of: isPrimary) { _, newValue in
      withAnimation(.interpolatingSpring(mass: 0.8, stiffness: 350, damping: 22, initialVelocity: 0)) {
        gradientProgress = newValue ? 1 : 0
      }
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
        colorScheme: .dark,
        onArchive: {},
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
        colorScheme: .dark,
        onArchive: {},
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
        colorScheme: .dark,
        onArchive: {},
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
        colorScheme: .dark,
        onArchive: {},
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
        colorScheme: .dark,
        onArchive: nil,
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
        colorScheme: .dark,
        onArchive: nil,
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
        colorScheme: .dark,
        onArchive: {},
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
        colorScheme: .light,
        onArchive: {},
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
        colorScheme: .light,
        onArchive: {},
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
