//
//  WelcomeView.swift
//  AgentHub
//
//  Rich welcome/onboarding view for the empty state.
//

import SwiftUI

// MARK: - WelcomeView

/// Rich welcome screen shown when no session is selected.
public struct WelcomeView: View {
  let viewModel: CLISessionsViewModel
  let onStartSession: (String?) -> Void

  @Environment(\.colorScheme) private var colorScheme

  public init(viewModel: CLISessionsViewModel, onStartSession: @escaping (String?) -> Void) {
    self.viewModel = viewModel
    self.onStartSession = onStartSession
  }

  public var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        heroSection
        quickStartSection

        if !recentRepositories.isEmpty {
          recentRepositoriesSection
        }

        tipsSection
      }
      .padding(28)
      .frame(maxWidth: 760)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(backgroundGradient)
  }

  // MARK: - Hero Section

  private var heroSection: some View {
    VStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(Color.brandPrimary.opacity(0.1))
          .frame(width: 76, height: 76)

        Image(systemName: "apple.terminal.on.rectangle")
          .font(.system(size: 30))
          .foregroundColor(.brandPrimary)
      }

      VStack(spacing: 6) {
        Text("Welcome to AgentHub")
          .font(.system(size: 22, weight: .semibold, design: .monospaced))
          .foregroundColor(.primary)

        Text("Start a new session with Claude, Codex, or both.")
          .font(.system(size: 12, weight: .regular, design: .monospaced))
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }

      Button(action: {
        onStartSession(latestRecentRepositoryPath)
      }) {
        HStack(spacing: 8) {
          Image(systemName: "plus.circle.fill")
            .font(.system(size: 13))
          Text("Start New Session")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .foregroundColor(colorScheme == .dark ? .black : .white)
        .frame(height: 36)
        .padding(.horizontal, 20)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(Color.brandPrimary)
        )
        .shadow(color: Color.brandPrimary.opacity(0.28), radius: 6, y: 3)
      }
      .buttonStyle(.plain)
      .padding(.top, 2)
    }
  }

  // MARK: - Quick Start Section

  private var quickStartSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader(title: "Quick Start", icon: "bolt.fill")

      VStack(spacing: 10) {
        shortcutRow(key: "⌘ N", description: "Start new session", icon: "plus.circle")
        shortcutRow(key: "⌘ K", description: "Command palette", icon: "command")
        shortcutRow(key: "⌘ B", description: "Toggle sidebar", icon: "sidebar.left")
        shortcutRow(key: "⌘ [ / ]", description: "Navigate history", icon: "arrow.left.arrow.right")
        shortcutRow(key: "⌘ ,", description: "Open settings", icon: "gearshape")
      }
      .padding(14)
      .background(cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }

  // MARK: - Recent Repositories Section

  private var recentRepositoriesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader(title: "Recent Repositories", icon: "folder.fill")

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        ForEach(recentRepositories, id: \.path) { repo in
          repositoryCard(repo)
        }
      }
    }
  }

  private func repositoryCard(_ repo: SelectedRepository) -> some View {
    Button(action: { onStartSession(repo.path) }) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: "folder.fill")
            .font(.system(size: 14))
            .foregroundColor(.primary)

          Spacer()

          if hasActiveSessions(for: repo) {
            Circle()
              .fill(Color.green)
              .frame(width: 6, height: 6)
          }
        }

        Text(repoName(repo))
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundColor(.primary)
          .lineLimit(1)

        Text(repoPath(repo))
          .font(.system(size: 10, weight: .regular, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(1)

        HStack(spacing: 4) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 8))
          Text("\(repo.worktrees.count)")
            .font(.system(size: 10, design: .monospaced))
        }
        .foregroundColor(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(height: 96, alignment: .topLeading)
      .background(cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Tips Section

  private var tipsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionHeader(title: "Pro Tips", icon: "lightbulb.fill")

      VStack(spacing: 10) {
        tipRow(
          icon: "folder.badge.plus",
          title: "Easy Worktree Management",
          description: "Create and manage worktrees quickly from the launcher."
        )
        tipRow(
          icon: "square.grid.2x2",
          title: "Layout Modes",
          description: "Switch between single, list, and grid views."
        )
        tipRow(
          icon: "arrow.left.arrow.right",
          title: "Fast Navigation",
          description: "Use command palette and history shortcuts."
        )
      }
      .padding(14)
      .background(cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }

  // MARK: - Helper Views

  private func sectionHeader(title: String, icon: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: icon)
        .font(.system(size: 11))
        .foregroundColor(.brandPrimary)

      Text(title)
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundColor(.primary)
    }
  }

  private func shortcutRow(key: String, description: String, icon: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .foregroundColor(.brandPrimary)
        .frame(width: 16)

      Text(description)
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundColor(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(key)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundColor(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(0.06))
        )
    }
  }

  private func tipRow(icon: String, title: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .foregroundColor(.brandSecondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundColor(.primary)

        Text(description)
          .font(.system(size: 10, weight: .regular, design: .monospaced))
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Helpers

  private var recentRepositories: [SelectedRepository] {
    Array(viewModel.selectedRepositories.suffix(4).reversed())
  }

  private var latestRecentRepositoryPath: String? {
    viewModel.selectedRepositories.last?.path
  }

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
    viewModel.monitoredSessions.contains { monitored in
      repo.worktrees.contains { $0.path == monitored.session.projectPath }
    }
  }

  // MARK: - Background

  private var backgroundGradient: some View {
    colorScheme == .dark ? Color.black : Color.white
  }

  private var cardBackground: some View {
    if colorScheme == .dark {
      Color(white: 0.12)
    } else {
      Color.white
    }
  }
}
