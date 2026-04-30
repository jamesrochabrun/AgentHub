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
  var onStartNewSession: ((String, SessionProviderKind) -> Void)?
  var session: CLISession?
  var onPopOut: (() -> Void)?

  @State private var viewModel = GitHubViewModel()
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  public init(
    projectPath: String,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false,
    session: CLISession? = nil,
    onSendToSession: ((String, CLISession) -> Void)? = nil,
    onStartNewSession: ((String, SessionProviderKind) -> Void)? = nil,
    onPopOut: (() -> Void)? = nil
  ) {
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    self.session = session
    self.onSendToSession = onSendToSession
    self.onStartNewSession = onStartNewSession
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
    .background(panelBackground)
    .task {
      await viewModel.setup(repoPath: projectPath)
      if viewModel.setupState == .ready {
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
        .foregroundStyle(accent)

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

      Button("Close") { onDismiss() }
        .controlSize(.small)
    }
    .padding(.horizontal, DesignTokens.Spacing.sm)
    .frame(height: AgentHubLayout.topBarHeight)
    .background(headerBackground)
  }

  private var accent: Color {
    Color.brandPrimary(from: runtimeTheme)
  }

  private var panelBackground: Color {
    Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
  }

  private var headerBackground: Color {
    Color.adaptiveExpandedContentBackground(for: colorScheme, theme: runtimeTheme)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch viewModel.setupState {
    case .checking:
      loadingView("Checking GitHub setup...")
    case .ghNotInstalled:
      ghNotInstalledView
    case .notAuthenticated:
      ghNotAuthenticatedView
    case .ready:
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
        badge: { tab in
          switch tab {
          case .pullRequests: return viewModel.pullRequests.isEmpty ? nil : viewModel.pullRequests.count
          case .issues: return viewModel.issues.isEmpty ? nil : viewModel.issues.count
          }
        },
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

      // Tab content
      switch viewModel.selectedTab {
      case .pullRequests:
        prContent
      case .issues:
        issueContent
      }
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
        onSendToSession: onSendToSession,
        onStartNewSession: onStartNewSession
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

      prFilterBar

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
        sectionedPRList
      }
    }
  }

  // MARK: - PR Filter Bar

  private var prFilterBar: some View {
    VStack(spacing: DesignTokens.Spacing.xs) {
      HStack(spacing: DesignTokens.Spacing.xs) {
        ForEach(GitHubPRFilter.allCases) { filter in
          FilterChipWithCount(
            title: filter.rawValue,
            count: viewModel.filterCount(filter),
            isActive: viewModel.prFilter == filter,
            accent: accent
          ) {
            viewModel.prFilter = filter
            Task { await viewModel.loadPullRequests() }
          }
        }

        Spacer()

        filterMenu
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
              .background(accent.opacity(0.12))
              .clipShape(Capsule())
            }
          }
        }
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
  }

  private var filterMenu: some View {
    Menu {
      Section("Scope") {
        Button {
          viewModel.showOnlyMyPRs.toggle()
          Task { await viewModel.loadPullRequests() }
        } label: {
          HStack {
            Text("Only my pull requests")
            if viewModel.showOnlyMyPRs { Image(systemName: "checkmark") }
          }
        }
      }

      if !viewModel.availableLabels.isEmpty {
        Section("Labels") {
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
        }
      }
    } label: {
      HStack(spacing: 5) {
        Text("Filter")
          .font(GitHubTypography.button)
          .foregroundStyle(.secondary)
        Text("/")
          .font(GitHubTypography.monoCaption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.secondary.opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .task { await viewModel.loadLabelsIfNeeded() }
  }

  // MARK: - Sectioned PR List

  private var sectionedPRList: some View {
    let currentBranchPR = viewModel.currentBranchPR
    let openPRs = viewModel.pullRequests
      .filter { $0.stateKind == .open && !$0.isDraft && $0.number != currentBranchPR?.number }
    let draftPRs = viewModel.pullRequests
      .filter { $0.isDraft && $0.number != currentBranchPR?.number }
    let mergedPRs = viewModel.pullRequests
      .filter { $0.stateKind == .merged && $0.number != currentBranchPR?.number }
      .prefix(5)
    let closedPRs = viewModel.pullRequests
      .filter { $0.stateKind == .closed && $0.number != currentBranchPR?.number }

    return ScrollView {
      LazyVStack(spacing: 0, pinnedViews: []) {
        if let branchPR = currentBranchPR,
           viewModel.pullRequests.contains(where: { $0.number == branchPR.number }) {
          GitHubSectionHeader(title: "Current Branch")
          GitHubPRRow(pr: branchPR, isCurrentBranch: true) {
            viewModel.selectPR(branchPR)
          }
        }

        if !openPRs.isEmpty {
          GitHubSectionHeader(title: "Open")
          ForEach(openPRs) { pr in
            GitHubPRRow(pr: pr, isCurrentBranch: false) {
              viewModel.selectPR(pr)
            }
          }
        }

        if !draftPRs.isEmpty {
          GitHubSectionHeader(title: "Draft")
          ForEach(draftPRs) { pr in
            GitHubPRRow(pr: pr, isCurrentBranch: false) {
              viewModel.selectPR(pr)
            }
          }
        }

        if !mergedPRs.isEmpty {
          GitHubSectionHeader(title: "Recently Merged")
          ForEach(Array(mergedPRs)) { pr in
            GitHubPRRow(pr: pr, isCurrentBranch: false) {
              viewModel.selectPR(pr)
            }
          }
        }

        if !closedPRs.isEmpty {
          GitHubSectionHeader(title: "Closed")
          ForEach(closedPRs) { pr in
            GitHubPRRow(pr: pr, isCurrentBranch: false) {
              viewModel.selectPR(pr)
            }
          }
        }
      }
      .padding(.bottom, DesignTokens.Spacing.md)
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
        tintColor: accent
      )
      StatCardView(
        value: "\(mergedCount)",
        label: "Merged",
        tintColor: GitHubPalette.merged
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
        onSendToSession: onSendToSession,
        onStartNewSession: onStartNewSession
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
          FilterChipWithCount(
            title: filter.rawValue,
            count: filter == viewModel.issueFilter ? viewModel.issues.count : 0,
            isActive: viewModel.issueFilter == filter,
            accent: accent
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
          LazyVStack(spacing: 0) {
            ForEach(viewModel.issues) { issue in
              GitHubIssueRow(issue: issue) {
                viewModel.selectIssue(issue)
              }
            }
          }
          .padding(.bottom, DesignTokens.Spacing.md)
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
        .tint(accent)
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
        .foregroundStyle(accent.opacity(0.5))

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
        .foregroundStyle(accent.opacity(0.5))

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

// MARK: - Section Header

struct GitHubSectionHeader: View {
  let title: String

  var body: some View {
    HStack {
      Text(title.uppercased())
        .font(GitHubTypography.caption)
        .tracking(0.8)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.top, DesignTokens.Spacing.md)
    .padding(.bottom, DesignTokens.Spacing.xs)
  }
}

// MARK: - Filter Chip With Count

struct FilterChipWithCount: View {
  let title: String
  let count: Int
  let isActive: Bool
  let accent: Color
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title)
          .font(GitHubTypography.button)
          .foregroundStyle(isActive ? accent : .secondary)
        if count > 0 {
          Text("\(count)")
            .font(GitHubTypography.monoCaption)
            .foregroundStyle(isActive ? accent : .secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
              (isActive ? accent : Color.secondary).opacity(colorScheme == .dark ? 0.18 : 0.14)
            )
            .clipShape(Capsule())
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous)
          .fill(isActive ? accent.opacity(colorScheme == .dark ? 0.15 : 0.12) : .clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous)
          .stroke(
            isActive ? accent.opacity(0.35) : Color.secondary.opacity(0.18),
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - PR Row

struct GitHubPRRow: View {
  let pr: GitHubPullRequest
  var isCurrentBranch: Bool = false
  let onSelect: () -> Void

  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        PRStatusDot(state: pr.stateKind, isDraft: pr.isDraft)

        if let author = pr.author {
          AuthorAvatarView(login: author.login, size: 26)
        }

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: DesignTokens.Spacing.xs) {
            Text(pr.title)
              .font(.geist(size: 13, weight: .semibold))
              .foregroundStyle(.primary)
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

          HStack(spacing: DesignTokens.Spacing.sm) {
            Text("#\(pr.number)")
              .font(GitHubTypography.monoCaption)
              .foregroundStyle(.tertiary)

            if let author = pr.author {
              Text("@\(author.login)")
                .font(GitHubTypography.caption)
                .foregroundStyle(.tertiary)
            }

            AdditionsDeletionsBadge(
              additions: pr.additions,
              deletions: pr.deletions
            )

            if let labels = pr.labels, !labels.isEmpty {
              ForEach(labels.prefix(1)) { label in
                GitHubLabelPill(label: label)
              }
            }
          }
        }

        Spacer()

        HStack(spacing: DesignTokens.Spacing.sm) {
          if let decision = pr.reviewDecision {
            ReviewDecisionBadge(decision: decision)
          }

          ciIcon(pr.ciStatus)

          if let updated = pr.updatedAt {
            Text(relativeTime(updated))
              .font(GitHubTypography.caption)
              .foregroundStyle(.tertiary)
              .monospacedDigit()
          }
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .agentHubFlatRow(isHighlighted: isCurrentBranch)
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

  @ViewBuilder
  private func ciIcon(_ status: CIStatus) -> some View {
    if status != .none {
      Image(systemName: status.icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(ciColor(status))
    }
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

// MARK: - PR Status Dot

private struct PRStatusDot: View {
  let state: GitHubPullRequestState
  let isDraft: Bool

  var body: some View {
    Circle()
      .fill(isFilled ? color : .clear)
      .overlay(Circle().stroke(color, lineWidth: isFilled ? 0 : 1.5))
      .frame(width: 8, height: 8)
  }

  private var isFilled: Bool {
    switch state {
    case .open: return !isDraft
    default: return false
    }
  }

  private var color: Color {
    switch state {
    case .open:   return isDraft ? .secondary : GitHubPalette.open
    case .closed: return GitHubPalette.closed
    case .merged: return GitHubPalette.merged
    case .unknown: return .secondary
    }
  }
}

// MARK: - Issue Row

struct GitHubIssueRow: View {
  let issue: GitHubIssue
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        IssueStatusDot(state: issue.stateKind)

        if let author = issue.author {
          AuthorAvatarView(login: author.login, size: 26)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(issue.title)
            .font(.geist(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          HStack(spacing: DesignTokens.Spacing.sm) {
            Text("#\(issue.number)")
              .font(GitHubTypography.monoCaption)
              .foregroundStyle(.tertiary)

            if let author = issue.author {
              Text("@\(author.login)")
                .font(GitHubTypography.caption)
                .foregroundStyle(.tertiary)
            }

            if let labels = issue.labels, !labels.isEmpty {
              ForEach(labels.prefix(2)) { label in
                GitHubLabelPill(label: label)
              }
            }
          }
        }

        Spacer()

        HStack(spacing: DesignTokens.Spacing.sm) {
          if let comments = issue.comments, !comments.isEmpty {
            HStack(spacing: 2) {
              Image(systemName: "bubble.right")
                .font(.system(size: 10))
              Text("\(comments.count)")
                .font(GitHubTypography.monoCaption)
            }
            .foregroundStyle(.secondary)
          }

          if let updated = issue.createdAt {
            Text(relativeTime(updated))
              .font(GitHubTypography.caption)
              .foregroundStyle(.tertiary)
              .monospacedDigit()
          }
        }
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, DesignTokens.Spacing.sm)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .agentHubFlatRow()
  }
}

private struct IssueStatusDot: View {
  let state: GitHubIssueState

  var body: some View {
    Circle()
      .fill(isFilled ? color : .clear)
      .overlay(Circle().stroke(color, lineWidth: isFilled ? 0 : 1.5))
      .frame(width: 8, height: 8)
  }

  private var isFilled: Bool { state == .open }

  private var color: Color {
    switch state {
    case .open: return GitHubPalette.open
    case .closed: return GitHubPalette.merged
    case .unknown: return .secondary
    }
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
