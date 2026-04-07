//
//  GitHubPanelView.swift
//  AgentHub
//
//  Main GitHub integration panel with PR list, issue list, and details
//

import AgentHubGitHub
import AppKit
import SwiftUI

// MARK: - GitHubPanelView

/// Panel view for GitHub integration — lists PRs, issues, and shows details
public struct GitHubPanelView: View {
  let projectPath: String
  let onDismiss: () -> Void
  var isEmbedded: Bool = false
  var onSendToSession: ((String, CLISession) -> Void)?
  var session: CLISession?
  var onPopOut: (() -> Void)?

  @State private var viewModel = GitHubViewModel()
  @Environment(\.colorScheme) private var colorScheme

  public init(
    projectPath: String,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false,
    session: CLISession? = nil,
    onSendToSession: ((String, CLISession) -> Void)? = nil,
    onPopOut: (() -> Void)? = nil
  ) {
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    self.session = session
    self.onSendToSession = onSendToSession
    self.onPopOut = onPopOut
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      GradientDivider()
      content
    }
    .frame(
      minWidth: isEmbedded ? 300 : 700, idealWidth: isEmbedded ? .infinity : 950, maxWidth: .infinity,
      minHeight: isEmbedded ? 300 : 550, idealHeight: isEmbedded ? .infinity : 750, maxHeight: .infinity
    )
    .background(colorScheme == .dark ? Color(white: 0.05) : Color(white: 0.97))
    .task {
      await viewModel.setup(repoPath: projectPath)
      if viewModel.isGHInstalled && viewModel.isAuthenticated {
        await viewModel.loadPullRequests()
        await viewModel.loadCurrentBranchPR()
      }
    }
    .alert("Error", isPresented: .init(
      get: { viewModel.errorMessage != nil },
      set: { if !$0 { viewModel.errorMessage = nil } }
    )) {
      Button("OK") { viewModel.errorMessage = nil }
    } message: {
      if let msg = viewModel.errorMessage {
        Text(msg)
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Image(systemName: "arrow.triangle.pull")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.brandPrimary)

      Text("GitHub")
        .font(GitHubTypography.panelTitle)

      if let info = viewModel.repoInfo {
        Text(info.fullName)
          .font(GitHubTypography.body)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if isEmbedded, let onPopOut {
        Button { onPopOut() } label: {
          Image(systemName: "rectangle.portrait.and.arrow.right")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Open in separate window")
      }

      Button { onDismiss() } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, DesignTokens.Spacing.lg)
    .padding(.vertical, DesignTokens.Spacing.md)
    .background(colorScheme == .dark ? Color(white: 0.08) : Color.white)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if !viewModel.isGHInstalled {
      ghNotInstalledView
    } else if !viewModel.isAuthenticated {
      ghNotAuthenticatedView
    } else {
      mainContent
    }
  }

  private var mainContent: some View {
    VStack(spacing: 0) {
      GitHubUnderlineTabBar(
        tabs: GitHubTab.allCases,
        selected: $viewModel.selectedTab,
        icon: { $0.icon },
        title: { $0.rawValue },
        onSelect: { tab in
          if tab == .issues && viewModel.issues.isEmpty {
            Task { await viewModel.loadIssues() }
          }
        },
        trailing: {
          AnyView(
            Button {
              Task {
                switch viewModel.selectedTab {
                case .pullRequests: await viewModel.loadPullRequests()
                case .issues: await viewModel.loadIssues()
                }
              }
            } label: {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(DesignTokens.Spacing.xs)
            }
            .buttonStyle(.plain)
          )
        }
      )

      GradientDivider()

      // Current branch PR banner
      if let branchPR = viewModel.currentBranchPR, viewModel.selectedPR == nil {
        currentBranchPRBanner(branchPR)
        GradientDivider()
      }

      // Tab content
      switch viewModel.selectedTab {
      case .pullRequests:
        prContent
      case .issues:
        issueContent
      }
    }
  }

  // MARK: - Current Branch PR Banner

  private func currentBranchPRBanner(_ pr: GitHubPullRequest) -> some View {
    CurrentBranchPRBannerView(pr: pr) {
      viewModel.selectPR(pr)
    }
  }

  // MARK: - PR Content

  @ViewBuilder
  private var prContent: some View {
    if let pr = viewModel.selectedPR {
      GitHubPRDetailView(
        viewModel: viewModel,
        pr: pr,
        session: session,
        onSendToSession: onSendToSession
      )
    } else {
      prListContent
    }
  }

  private var prListContent: some View {
    VStack(spacing: 0) {
      // Stats header
      if case .loaded = viewModel.prLoadingState, !viewModel.pullRequests.isEmpty {
        statsHeader
      }

      // Filter bar
      VStack(spacing: 4) {
        HStack(spacing: 4) {
          ForEach(GitHubPRFilter.allCases) { filter in
            Button {
              viewModel.prFilter = filter
              Task { await viewModel.loadPullRequests() }
            } label: {
              Text(filter.rawValue)
                .font(GitHubTypography.button)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                  viewModel.prFilter == filter
                    ? Color.secondary.opacity(0.2)
                    : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
          }

          Spacer()

          // Labels menu
          Menu {
            ForEach(viewModel.availableLabels) { label in
              Button {
                if viewModel.selectedLabels.contains(label.name) {
                  viewModel.selectedLabels.remove(label.name)
                } else {
                  viewModel.selectedLabels.insert(label.name)
                }
                Task { await viewModel.loadPullRequests() }
              } label: {
                HStack {
                  Text(label.name)
                  if viewModel.selectedLabels.contains(label.name) {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }

            if !viewModel.selectedLabels.isEmpty {
              Divider()
              Button("Clear all labels") {
                viewModel.selectedLabels.removeAll()
                Task { await viewModel.loadPullRequests() }
              }
            }
          } label: {
            HStack(spacing: 3) {
              Image(systemName: "tag")
                .font(.system(size: 10))
              Text("Labels")
                .font(GitHubTypography.button)
              if !viewModel.selectedLabels.isEmpty {
                Text("\(viewModel.selectedLabels.count)")
                  .font(GitHubTypography.badge)
                  .padding(.horizontal, 4)
                  .padding(.vertical, 1)
                  .background(Color.accentColor.opacity(0.2))
                  .clipShape(Capsule())
              }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
              viewModel.selectedLabels.isEmpty
                ? Color.clear
                : Color.accentColor.opacity(0.1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .task { await viewModel.loadLabelsIfNeeded() }

          // Mine toggle
          Button {
            viewModel.showOnlyMyPRs.toggle()
            Task { await viewModel.loadPullRequests() }
          } label: {
            Image(systemName: viewModel.showOnlyMyPRs ? "person.fill" : "person")
              .font(.system(size: 11))
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(
                viewModel.showOnlyMyPRs
                  ? Color.accentColor.opacity(0.2)
                  : Color.clear
              )
              .clipShape(RoundedRectangle(cornerRadius: 4))
          }
          .buttonStyle(.plain)
          .help("Show only my pull requests (no limit)")
        }

        // Active label chips
        if !viewModel.selectedLabels.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
              ForEach(viewModel.selectedLabels.sorted(), id: \.self) { label in
                HStack(spacing: 3) {
                  Text(label)
                    .font(GitHubTypography.badge)
                  Button {
                    viewModel.selectedLabels.remove(label)
                    Task { await viewModel.loadPullRequests() }
                  } label: {
                    Image(systemName: "xmark")
                      .font(.system(size: 8, weight: .bold))
                  }
                  .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(Capsule())
              }
            }
          }
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, DesignTokens.Spacing.sm)

      GradientDivider()

      // PR list
      switch viewModel.prLoadingState {
      case .loading:
        loadingView("Loading pull requests...")
      case .error(let msg):
        errorView(msg) {
          Task { await viewModel.loadPullRequests() }
        }
      case .loaded where viewModel.pullRequests.isEmpty:
        emptyView("No pull requests", "No \(viewModel.prFilter.rawValue.lowercased()) pull requests found.")
      default:
        ScrollView {
          LazyVStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(viewModel.pullRequests) { pr in
              GitHubPRRow(pr: pr) {
                viewModel.selectPR(pr)
              }
            }
          }
          .padding(.horizontal, DesignTokens.Spacing.md)
          .padding(.vertical, DesignTokens.Spacing.sm)
        }
      }
    }
  }

  private var statsHeader: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      let openCount = viewModel.pullRequests.filter { $0.stateKind == .open }.count
      let mergedCount = viewModel.pullRequests.filter { $0.stateKind == .merged }.count
      let totalLines = viewModel.pullRequests.reduce(0) { $0 + $1.additions + $1.deletions }

      StatCardView(
        value: "\(openCount)",
        label: "Open PRs",
        tintColor: GitHubPalette.merged
      )
      StatCardView(
        value: "\(mergedCount)",
        label: "Merged",
        tintColor: .secondary
      )
      StatCardView(
        value: abbreviateNumber(totalLines),
        label: "Lines Changed",
        tintColor: GitHubPalette.linesChanged
      )
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.top, DesignTokens.Spacing.md)
    .padding(.bottom, DesignTokens.Spacing.xs)
  }

  // MARK: - Issue Content

  @ViewBuilder
  private var issueContent: some View {
    if let issue = viewModel.selectedIssue {
      GitHubIssueDetailView(
        viewModel: viewModel,
        issue: issue,
        session: session,
        onSendToSession: onSendToSession
      )
    } else {
      issueListContent
    }
  }

  private var issueListContent: some View {
    VStack(spacing: 0) {
      // Filter bar
      HStack(spacing: DesignTokens.Spacing.xs) {
        ForEach(GitHubIssueFilter.allCases) { filter in
          GitHubFilterChip(
            title: filter.rawValue,
            isActive: viewModel.issueFilter == filter
          ) {
            viewModel.issueFilter = filter
            Task { await viewModel.loadIssues() }
          }
        }
        Spacer()
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, DesignTokens.Spacing.sm)

      GradientDivider()

      // Issue list
      switch viewModel.issueLoadingState {
      case .loading:
        loadingView("Loading issues...")
      case .error(let msg):
        errorView(msg) {
          Task { await viewModel.loadIssues() }
        }
      case .loaded where viewModel.issues.isEmpty:
        emptyView("No issues", "No \(viewModel.issueFilter.rawValue.lowercased()) issues found.")
      default:
        ScrollView {
          LazyVStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(viewModel.issues) { issue in
              GitHubIssueRow(issue: issue) {
                viewModel.selectIssue(issue)
              }
            }
          }
          .padding(.horizontal, DesignTokens.Spacing.md)
          .padding(.vertical, DesignTokens.Spacing.sm)
        }
      }
    }
  }

  // MARK: - Shared Components

  private func loadingView(_ message: String) -> some View {
    VStack(spacing: DesignTokens.Spacing.md) {
      Spacer()
      ProgressView()
        .scaleEffect(0.8)
        .tint(Color.brandPrimary)
      Text(message)
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private func errorView(_ message: String, retry: @escaping () -> Void) -> some View {
    VStack(spacing: DesignTokens.Spacing.md) {
      Spacer()
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 28))
        .foregroundStyle(.orange)
      Text(message)
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Retry") { retry() }
        .buttonStyle(.agentHubOutlined(tint: .orange))
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(DesignTokens.Spacing.lg)
  }

  private func emptyView(_ title: String, _ message: String) -> some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      Spacer()
      Image(systemName: "tray")
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(GitHubTypography.sectionTitle)
      Text(message)
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - GH Not Installed

  private var ghNotInstalledView: some View {
    VStack(spacing: DesignTokens.Spacing.lg) {
      Spacer()
      Image(systemName: "terminal")
        .font(.system(size: 36))
        .foregroundStyle(Color.brandPrimary.opacity(0.5))

      Text("GitHub CLI Not Installed")
        .font(GitHubTypography.sectionTitle)

      Text("Install the GitHub CLI to use GitHub integration.")
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Text("brew install gh")
        .font(GitHubTypography.monoBody)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .agentHubInset()
        .textSelection(.enabled)

      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(DesignTokens.Spacing.lg)
  }

  // MARK: - GH Not Authenticated

  private var ghNotAuthenticatedView: some View {
    VStack(spacing: DesignTokens.Spacing.lg) {
      Spacer()
      Image(systemName: "person.badge.key")
        .font(.system(size: 36))
        .foregroundStyle(Color.brandPrimary.opacity(0.5))

      Text("Not Authenticated")
        .font(GitHubTypography.sectionTitle)

      Text("Authenticate with GitHub CLI to access your repositories.")
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Text("gh auth login")
        .font(GitHubTypography.monoBody)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .agentHubInset()
        .textSelection(.enabled)

      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(DesignTokens.Spacing.lg)
  }
}

// MARK: - Current Branch PR Banner

private struct CurrentBranchPRBannerView: View {
  let pr: GitHubPullRequest
  let onSelect: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 0) {
        // Left accent bar
        Rectangle()
          .fill(Color.brandPrimary)
          .frame(width: 3)

        HStack(spacing: DesignTokens.Spacing.sm) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.brandPrimary)

          Text("Current branch:")
            .font(GitHubTypography.caption)
            .foregroundStyle(.secondary)

          Text("#\(pr.number)")
            .font(GitHubTypography.monoStrong)
            .foregroundStyle(Color.brandPrimary)

          Text(pr.title)
            .font(GitHubTypography.button)
            .lineLimit(1)

          Spacer()

          CIStatusBadge(status: pr.ciStatus)

          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
      }
      .fixedSize(horizontal: false, vertical: true)
      .background(
        LinearGradient(
          colors: [
            Color.brandPrimary.opacity(isHovered ? 0.1 : 0.06),
            Color.brandPrimary.opacity(isHovered ? 0.04 : 0.02)
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovered)
  }
}

// MARK: - PR Row

struct GitHubPRRow: View {
  let pr: GitHubPullRequest
  let onSelect: () -> Void

  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 0) {
        // Left state accent bar
        RoundedRectangle(cornerRadius: 2)
          .fill(prStateColor)
          .frame(width: 3)
          .padding(.vertical, DesignTokens.Spacing.xs)

        HStack(spacing: DesignTokens.Spacing.sm) {
          // Author avatar
          if let author = pr.author {
            AuthorAvatarView(login: author.login, size: 28)
          }

          VStack(alignment: .leading, spacing: 3) {
            // Title row
            HStack(spacing: DesignTokens.Spacing.xs) {
              Text("#\(pr.number)")
                .font(GitHubTypography.monoStrong)
                .foregroundStyle(Color.brandPrimary)

              Text(pr.title)
                .font(.geist(size: 12, weight: .semibold))
                .lineLimit(1)

              if pr.isDraft {
                Text("Draft")
                  .font(GitHubTypography.badge)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(Color.secondary.opacity(0.15))
                  .foregroundStyle(.secondary)
                  .clipShape(Capsule())
              }
            }

            // Metadata row
            HStack(spacing: DesignTokens.Spacing.sm) {
              if let author = pr.author {
                Text(author.login)
                  .font(GitHubTypography.caption)
                  .foregroundStyle(.tertiary)
              }

              BranchBadge(name: pr.headRefName)

              if let labels = pr.labels, !labels.isEmpty {
                ForEach(labels.prefix(2)) { label in
                  GitHubLabelPill(label: label)
                }
              }
            }
          }

          Spacer()

          // Right side: stats + badges
          HStack(spacing: DesignTokens.Spacing.sm) {
            if pr.changedFiles > 0 {
              HStack(spacing: 2) {
                Image(systemName: "doc")
                  .font(.system(size: 9))
                Text("\(pr.changedFiles)")
                  .font(GitHubTypography.monoCaption)
              }
              .foregroundStyle(.secondary)
            }

            AdditionsDeletionsBadge(
              additions: pr.additions,
              deletions: pr.deletions
            )

            if let decision = pr.reviewDecision {
              ReviewDecisionBadge(decision: decision)
            }

            ciIcon(pr.ciStatus)

            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
      }
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .fill(rowBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .stroke(
            isHovered ? Color.brandPrimary.opacity(0.3) : Color.secondary.opacity(0.15),
            lineWidth: 1
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovered)
    .contextMenu {
      Button {
        if let url = URL(string: pr.url) {
          NSWorkspace.shared.open(url)
        }
      } label: {
        Label("Open in Browser", systemImage: "safari")
      }
    }
  }

  private var prStateColor: Color {
    switch pr.stateKind {
    case .open: return pr.isDraft ? .secondary : GitHubPalette.open
    case .closed: return GitHubPalette.closed
    case .merged: return GitHubPalette.merged
    case .unknown: return .secondary
    }
  }

  private var rowBackground: Color {
    if isHovered {
      return colorScheme == .dark ? Color(white: 0.10) : Color(white: 0.96)
    }
    return colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.98)
  }

  private func ciIcon(_ status: CIStatus) -> some View {
    Image(systemName: status.icon)
      .font(.system(size: 10))
      .foregroundStyle(ciColor(status))
  }

  private func ciColor(_ status: CIStatus) -> Color {
    switch status {
    case .success: return GitHubPalette.addition
    case .failure: return GitHubPalette.deletion
    case .pending: return .orange
    case .none: return .clear
    }
  }
}

// MARK: - Issue Row

struct GitHubIssueRow: View {
  let issue: GitHubIssue
  let onSelect: () -> Void

  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 0) {
        // Left state accent bar
        RoundedRectangle(cornerRadius: 2)
          .fill(issueStateColor)
          .frame(width: 3)
          .padding(.vertical, DesignTokens.Spacing.xs)

        HStack(spacing: DesignTokens.Spacing.sm) {
          // Author avatar
          if let author = issue.author {
            AuthorAvatarView(login: author.login, size: 28)
          }

          VStack(alignment: .leading, spacing: 3) {
            // Title row
            HStack(spacing: DesignTokens.Spacing.xs) {
              Text("#\(issue.number)")
                .font(GitHubTypography.monoStrong)
                .foregroundStyle(Color.brandPrimary)

              Text(issue.title)
                .font(.geist(size: 12, weight: .semibold))
                .lineLimit(1)
            }

            // Metadata row
            HStack(spacing: DesignTokens.Spacing.sm) {
              if let author = issue.author {
                Text(author.login)
                  .font(GitHubTypography.caption)
                  .foregroundStyle(.tertiary)
              }

              if let labels = issue.labels, !labels.isEmpty {
                ForEach(labels.prefix(3)) { label in
                  GitHubLabelPill(label: label)
                }
              }

              if let timeAgo = issue.createdAt.map(relativeTime) {
                Text(timeAgo)
                  .font(GitHubTypography.caption)
                  .foregroundStyle(.tertiary)
              }
            }
          }

          Spacer()

          HStack(spacing: DesignTokens.Spacing.sm) {
            if let comments = issue.comments, !comments.isEmpty {
              HStack(spacing: 2) {
                Image(systemName: "bubble.right")
                  .font(.system(size: 9))
                Text("\(comments.count)")
                  .font(GitHubTypography.monoCaption)
              }
              .foregroundStyle(.secondary)
            }

            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
      }
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .fill(rowBackground)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
          .stroke(
            isHovered ? Color.brandPrimary.opacity(0.3) : Color.secondary.opacity(0.15),
            lineWidth: 1
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovered)
  }

  private var issueStateColor: Color {
    switch issue.stateKind {
    case .open: return GitHubPalette.open
    case .closed: return GitHubPalette.merged
    case .unknown: return .secondary
    }
  }

  private var rowBackground: Color {
    if isHovered {
      return colorScheme == .dark ? Color(white: 0.10) : Color(white: 0.96)
    }
    return colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.98)
  }
}

// MARK: - Helpers

func relativeTime(_ date: Date) -> String {
  let interval = Date().timeIntervalSince(date)
  if interval < 60 { return "just now" }
  if interval < 3600 { return "\(Int(interval / 60))m ago" }
  if interval < 86400 { return "\(Int(interval / 3600))h ago" }
  if interval < 604800 { return "\(Int(interval / 86400))d ago" }
  let formatter = DateFormatter()
  formatter.dateStyle = .short
  return formatter.string(from: date)
}
