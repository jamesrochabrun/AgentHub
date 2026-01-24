//
//  GitHubRepositoryPickerView.swift
//  AgentHub
//
//  View to browse and select GitHub repositories for cloning
//

import SwiftUI

// MARK: - GitHubRepositoryPickerView

/// A sheet view for browsing and selecting GitHub repositories to clone
///
/// Note: In the current implementation, this view displays placeholder repository data.
/// In production, repository data should be provided by the host application via MCP tools
/// or another data source. The view accepts repositories through callbacks and does not
/// directly access GitHub APIs - this allows the host to handle authentication and API calls.
public struct GitHubRepositoryPickerView: View {
  let onSelect: (GitHubRepository) -> Void
  let onDismiss: () -> Void

  @State private var searchQuery: String = ""
  @State private var isLoading: Bool = false
  @State private var repositories: [GitHubRepository] = []
  @State private var selectedRepository: GitHubRepository?
  @State private var errorMessage: String?

  // URL clone state
  @State private var urlInput: String = ""
  @State private var parsedUrlRepository: GitHubRepository?

  public init(
    onSelect: @escaping (GitHubRepository) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.onSelect = onSelect
    self.onDismiss = onDismiss
  }

  public var body: some View {
    VStack(spacing: 0) {
      // Header
      headerSection

      Divider()

      // Search bar and URL input
      VStack(spacing: 8) {
        searchBar
        urlInputField
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Divider()

      // Repository list
      if isLoading {
        loadingView
      } else if let error = errorMessage {
        errorView(message: error)
      } else if repositories.isEmpty {
        emptyStateView
      } else {
        repositoryList
      }

      Divider()

      // Action buttons
      actionButtons
        .padding(16)
    }
    .frame(width: 500, height: 600)
    .task {
      await loadRepositories()
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    HStack {
      HStack(spacing: 8) {
        Image(systemName: "network")
          .font(.title2)
          .foregroundColor(.brandPrimary)

        Text("Clone from GitHub")
          .font(.headline)
      }

      Spacer()

      Button(action: onDismiss) {
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(16)
  }

  // MARK: - Search Bar

  private var searchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(.secondary)

      TextField("Search repositories...", text: $searchQuery)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .onSubmit {
          Task { await searchRepositories() }
        }

      if !searchQuery.isEmpty {
        Button(action: { searchQuery = "" }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  // MARK: - URL Input Field

  private var urlInputField: some View {
    HStack(spacing: 8) {
      Image(systemName: "link.circle")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(.secondary)

      TextField("Paste GitHub URL to clone...", text: $urlInput)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .onChange(of: urlInput) { _, newValue in
          // Parse URL and update state
          parsedUrlRepository = parseGitHubUrl(newValue)
          // Clear list selection when URL is entered
          if parsedUrlRepository != nil {
            selectedRepository = nil
          }
        }

      if !urlInput.isEmpty {
        Button(action: {
          urlInput = ""
          parsedUrlRepository = nil
        }) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(parsedUrlRepository != nil ? Color.brandPrimary.opacity(0.5) : Color.borderSubtle, lineWidth: 1)
    )
  }

  // MARK: - Repository List

  private var repositoryList: some View {
    ScrollView {
      LazyVStack(spacing: 8) {
        ForEach(filteredRepositories) { repo in
          repositoryRow(repo)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  }

  private func repositoryRow(_ repo: GitHubRepository) -> some View {
    let isSelected = selectedRepository?.id == repo.id

    return Button(action: {
      selectedRepository = repo
      // Clear URL input when selecting from list
      urlInput = ""
      parsedUrlRepository = nil
    }) {
      HStack(spacing: 12) {
        // Repository icon
        Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
          .font(.system(size: DesignTokens.IconSize.lg))
          .foregroundColor(repo.isPrivate ? .orange : .brandPrimary)
          .frame(width: 24)

        // Repository info
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text(repo.name)
              .font(.system(.body, weight: .medium))
              .foregroundColor(.primary)

            if repo.isPrivate {
              Text("Private")
                .font(.caption2)
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                  Capsule()
                    .fill(Color.orange.opacity(0.15))
                )
            }
          }

          if let description = repo.description, !description.isEmpty {
            Text(description)
              .font(.caption)
              .foregroundColor(.secondary)
              .lineLimit(2)
          }

          Text(repo.fullName)
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.8))
        }

        Spacer()

        // Selection indicator
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18))
            .foregroundColor(.brandPrimary)
        }
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .fill(isSelected ? Color.brandPrimary.opacity(0.1) : Color.surfaceOverlay)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .stroke(isSelected ? Color.brandPrimary.opacity(0.5) : Color.borderSubtle, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Loading View

  private var loadingView: some View {
    VStack(spacing: 12) {
      ProgressView()
        .scaleEffect(0.8)
      Text("Loading repositories...")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Error View

  private func errorView(message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 32))
        .foregroundColor(.orange)

      Text("Failed to load repositories")
        .font(.headline)

      Text(message)
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)

      Button("Try Again") {
        Task { await loadRepositories() }
      }
      .buttonStyle(.borderedProminent)
      .tint(.brandPrimary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Empty State

  private var emptyStateView: some View {
    VStack(spacing: 16) {
      Image(systemName: "folder.badge.questionmark")
        .font(.system(size: 40))
        .foregroundColor(.secondary.opacity(0.6))

      Text("No repositories found")
        .font(.headline)
        .foregroundColor(.secondary)

      Text("Search for repositories or check your GitHub connection.")
        .font(.caption)
        .foregroundColor(.secondary.opacity(0.8))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack {
      Button("Cancel") {
        onDismiss()
      }
      .keyboardShortcut(.escape)

      Spacer()

      Button(action: {
        if let repo = repositoryToClone {
          onSelect(repo)
        }
      }) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.down.circle")
          Text("Clone Repository")
        }
      }
      .keyboardShortcut(.return)
      .disabled(!canClone)
      .buttonStyle(.borderedProminent)
      .tint(.brandPrimary)
    }
  }

  // MARK: - Computed Properties

  private var filteredRepositories: [GitHubRepository] {
    if searchQuery.isEmpty {
      return repositories
    }
    let query = searchQuery.lowercased()
    return repositories.filter { repo in
      repo.name.lowercased().contains(query) ||
      repo.fullName.lowercased().contains(query) ||
      (repo.description?.lowercased().contains(query) ?? false)
    }
  }

  // MARK: - Data Loading

  private func loadRepositories() async {
    isLoading = true
    errorMessage = nil

    // Placeholder data for now - will be replaced with MCP tool calls in PS3
    // Using realistic sample data that mimics GitHub API response
    try? await Task.sleep(for: .milliseconds(500))

    repositories = [
      GitHubRepository(
        id: 1,
        name: "AgentHub",
        fullName: "user/AgentHub",
        htmlUrl: "https://github.com/user/AgentHub",
        cloneUrl: "https://github.com/user/AgentHub.git",
        description: "macOS app for managing Claude Code sessions",
        isPrivate: false
      ),
      GitHubRepository(
        id: 2,
        name: "my-project",
        fullName: "user/my-project",
        htmlUrl: "https://github.com/user/my-project",
        cloneUrl: "https://github.com/user/my-project.git",
        description: "A sample project with Swift and SwiftUI",
        isPrivate: true
      ),
      GitHubRepository(
        id: 3,
        name: "dotfiles",
        fullName: "user/dotfiles",
        htmlUrl: "https://github.com/user/dotfiles",
        cloneUrl: "https://github.com/user/dotfiles.git",
        description: "Personal configuration files",
        isPrivate: false
      )
    ]

    isLoading = false
  }

  private func searchRepositories() async {
    guard !searchQuery.isEmpty else {
      await loadRepositories()
      return
    }

    isLoading = true
    errorMessage = nil

    // Placeholder - will be replaced with MCP tool calls in PS3
    try? await Task.sleep(for: .milliseconds(300))

    // Filter existing repos as placeholder for actual search
    isLoading = false
  }

  // MARK: - URL Parsing

  /// Parses a GitHub URL and returns a GitHubRepository if valid
  /// Supports formats:
  /// - https://github.com/owner/repo
  /// - https://github.com/owner/repo.git
  /// - https://github.com/owner/repo/ (trailing slash)
  private func parseGitHubUrl(_ urlString: String) -> GitHubRepository? {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Must start with https://github.com/
    guard trimmed.lowercased().hasPrefix("https://github.com/") else { return nil }

    // Extract path after github.com/
    guard let url = URL(string: trimmed) else { return nil }
    let pathComponents = url.pathComponents.filter { $0 != "/" }

    // Need at least owner and repo
    guard pathComponents.count >= 2 else { return nil }

    let owner = pathComponents[0]
    var repoName = pathComponents[1]

    // Remove .git suffix if present
    if repoName.hasSuffix(".git") {
      repoName = String(repoName.dropLast(4))
    }

    // Validate owner and repo are not empty
    guard !owner.isEmpty, !repoName.isEmpty else { return nil }

    let fullName = "\(owner)/\(repoName)"
    let htmlUrl = "https://github.com/\(fullName)"
    let cloneUrl = "https://github.com/\(fullName).git"

    // Use negative ID to distinguish from API-fetched repos
    return GitHubRepository(
      id: -abs(fullName.hashValue),
      name: repoName,
      fullName: fullName,
      htmlUrl: htmlUrl,
      cloneUrl: cloneUrl,
      description: nil,
      isPrivate: false  // Assume public since we can't verify
    )
  }

  /// Returns the repository to clone (URL-parsed takes priority, then selected)
  private var repositoryToClone: GitHubRepository? {
    parsedUrlRepository ?? selectedRepository
  }

  /// Whether the clone button should be enabled
  private var canClone: Bool {
    repositoryToClone != nil
  }
}

// MARK: - Preview

#Preview {
  GitHubRepositoryPickerView(
    onSelect: { repo in
      print("Selected: \(repo.name)")
    },
    onDismiss: { }
  )
}
