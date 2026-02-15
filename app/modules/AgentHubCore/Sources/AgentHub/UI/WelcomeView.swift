//
//  WelcomeView.swift
//  AgentHub
//
//  Rich welcome/onboarding view for the empty state
//

import SwiftUI

// MARK: - WelcomeView

/// Rich welcome screen shown when no session is selected
public struct WelcomeView: View {
  let viewModel: CLISessionsViewModel
  let onStartSession: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  public init(viewModel: CLISessionsViewModel, onStartSession: @escaping () -> Void) {
    self.viewModel = viewModel
    self.onStartSession = onStartSession
  }

  public var body: some View {
    ScrollView {
      VStack(spacing: 32) {
        // Hero section
        heroSection

        // Quick start guide
        quickStartSection

        // Recent repositories
        if !viewModel.selectedRepositories.isEmpty {
          recentRepositoriesSection
        }

        // Tips section
        tipsSection
      }
      .padding(40)
      .frame(maxWidth: 800)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(backgroundGradient)
  }

  // MARK: - Hero Section

  private var heroSection: some View {
    VStack(spacing: 20) {
      // App icon/logo area
      ZStack {
        Circle()
          .fill(Color.brandPrimary(from: runtimeTheme).opacity(0.1))
          .frame(width: 100, height: 100)

        Image(systemName: "terminal.fill")
          .font(.system(size: 44))
          .foregroundColor(Color.brandPrimary(from: runtimeTheme))
      }

      VStack(spacing: 8) {
        Text("Welcome to AgentHub")
          .font(.system(size: 32, weight: .bold))
          .foregroundColor(.primary)

        Text("Start a new session to begin working with Claude Code")
          .font(.system(size: 15))
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }

      // Primary CTA button
      Button(action: onStartSession) {
        HStack(spacing: 12) {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 18))
          Text("Start New Session")
            .font(.system(size: 16, weight: .semibold))
        }
        .foregroundColor(.white)
        .frame(height: 44)
        .padding(.horizontal, 32)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.brandPrimary(from: runtimeTheme))
        )
        .shadow(color: Color.brandPrimary(from: runtimeTheme).opacity(0.3), radius: 8, y: 4)
      }
      .buttonStyle(.plain)
      .padding(.top, 8)
    }
  }

  // MARK: - Quick Start Section

  private var quickStartSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(title: "Quick Start", icon: "bolt.fill")

      VStack(spacing: 12) {
        shortcutRow(
          key: "⌘ N",
          description: "Start new session",
          icon: "plus.circle"
        )

        shortcutRow(
          key: "⌘ K",
          description: "Command palette",
          icon: "command"
        )

        shortcutRow(
          key: "⌘ F",
          description: "Focus search",
          icon: "magnifyingglass"
        )

        shortcutRow(
          key: "⌘ 1/2/3",
          description: "Switch sessions",
          icon: "square.stack.3d.up"
        )

        shortcutRow(
          key: "⌘ [ / ]",
          description: "Navigate history",
          icon: "arrow.left.arrow.right"
        )

        shortcutRow(
          key: "⌘ ,",
          description: "Open settings",
          icon: "gearshape"
        )
      }
      .padding(20)
      .background(cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  // MARK: - Recent Repositories Section

  private var recentRepositoriesSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(title: "Recent Repositories", icon: "folder.fill")

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        ForEach(viewModel.selectedRepositories.prefix(4), id: \.path) { repo in
          repositoryCard(repo)
        }
      }
    }
  }

  private func repositoryCard(_ repo: SelectedRepository) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "folder.fill")
          .font(.system(size: 20))
          .foregroundColor(Color.brandPrimary(from: runtimeTheme))

        Spacer()

        if hasActiveSessions(for: repo) {
          Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
        }
      }

      Text(repoName(repo))
        .font(.system(size: 14, weight: .semibold))
        .foregroundColor(.primary)
        .lineLimit(1)

      Text(repoPath(repo))
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .lineLimit(1)

      Spacer()

      HStack(spacing: 4) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 10))
        Text("\(repo.worktrees.count)")
          .font(.system(size: 11))
      }
      .foregroundColor(.secondary)
    }
    .padding(16)
    .frame(height: 120)
    .background(cardBackground)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
    )
  }

  // MARK: - Tips Section

  private var tipsSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      sectionHeader(title: "Pro Tips", icon: "lightbulb.fill")

      VStack(spacing: 12) {
        tipRow(
          icon: "folder.badge.plus",
          title: "Multiple Projects",
          description: "Add multiple repositories to track sessions across different projects"
        )

        tipRow(
          icon: "square.grid.2x2",
          title: "Layout Modes",
          description: "Switch between single, list, and grid views using the layout toggle"
        )

        tipRow(
          icon: "paintbrush.fill",
          title: "Custom Themes",
          description: "Create your own color themes with YAML files for a personalized experience"
        )
      }
      .padding(20)
      .background(cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }

  // MARK: - Helper Views

  private func sectionHeader(title: String, icon: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 14))
        .foregroundColor(Color.brandPrimary(from: runtimeTheme))

      Text(title)
        .font(.system(size: 18, weight: .semibold))
        .foregroundColor(.primary)
    }
  }

  private func shortcutRow(key: String, description: String, icon: String) -> some View {
    HStack(spacing: 16) {
      Image(systemName: icon)
        .font(.system(size: 16))
        .foregroundColor(Color.brandPrimary(from: runtimeTheme))
        .frame(width: 24)

      Text(description)
        .font(.system(size: 14))
        .foregroundColor(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(key)
        .font(.system(size: 13, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.06))
        )
    }
  }

  private func tipRow(icon: String, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: icon)
        .font(.system(size: 18))
        .foregroundColor(Color.brandSecondary(from: runtimeTheme))
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.primary)

        Text(description)
          .font(.system(size: 13))
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Helpers

  private func repoName(_ repo: SelectedRepository) -> String {
    URL(fileURLWithPath: repo.path).lastPathComponent
  }

  private func repoPath(_ repo: SelectedRepository) -> String {
    let url = URL(fileURLWithPath: repo.path)
    let components = url.pathComponents
    if components.count > 3 {
      return ".../" + components.suffix(2).joined(separator: "/")
    }
    return repo.path
  }

  private func hasActiveSessions(for repo: SelectedRepository) -> Bool {
    viewModel.monitoredSessions.contains { session in
      repo.worktrees.contains { $0.path == session.session.projectPath }
    }
  }

  // MARK: - Background

  private var backgroundGradient: some View {
    ZStack {
      Color.surfaceCanvas

      // Subtle gradient overlay
      LinearGradient(
        colors: [
          Color.brandPrimary(from: runtimeTheme).opacity(0.03),
          Color.brandSecondary(from: runtimeTheme).opacity(0.02),
          Color.clear
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    }
  }

  private var cardBackground: some View {
    ZStack {
      if colorScheme == .dark {
        Color(white: 0.12)
      } else {
        Color.white
      }
    }
  }
}

// MARK: - Preview

#Preview {
  let service = CLISessionMonitorService()
  let viewModel = CLISessionsViewModel(
    monitorService: service,
    fileWatcher: SessionFileWatcher(),
    searchService: GlobalSearchService(),
    cliConfiguration: .claudeDefault,
    providerKind: .claude
  )

  WelcomeView(viewModel: viewModel, onStartSession: {})
    .frame(width: 800, height: 700)
}
