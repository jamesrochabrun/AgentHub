//
//  GitHubPanelView.swift
//  AgentHub
//
//  Main GitHub integration panel with PR list, issue list, and details
//

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

  @State private var viewModel = GitHubViewModel()
  @Environment(\.colorScheme) private var colorScheme

  public init(
    projectPath: String,
    onDismiss: @escaping () -> Void,
    isEmbedded: Bool = false,
    session: CLISession? = nil,
    onSendToSession: ((String, CLISession) -> Void)? = nil
  ) {
    self.projectPath = projectPath
    self.onDismiss = onDismiss
    self.isEmbedded = isEmbedded
    self.session = session
    self.onSendToSession = onSendToSession
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
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
    HStack(spacing: 8) {
      Image(systemName: "arrow.triangle.pull")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.secondary)

      Text("GitHub")
        .font(GitHubTypography.panelTitle)

      if let info = viewModel.repoInfo {
        Text(info.fullName)
          .font(GitHubTypography.body)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if !isEmbedded {
        Button { onDismiss() } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
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
      // Tab bar
      tabBar

      Divider()

      // Current branch PR banner
      if let branchPR = viewModel.currentBranchPR, viewModel.selectedPR == nil {
        currentBranchPRBanner(branchPR)
        Divider()
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

  // MARK: - Tab Bar

  private var tabBar: some View {
    HStack(spacing: 2) {
      ForEach(GitHubTab.allCases) { tab in
        Button {
          viewModel.selectedTab = tab
          if tab == .issues && viewModel.issues.isEmpty {
            Task { await viewModel.loadIssues() }
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: tab.icon)
              .font(.system(size: 11))
            Text(tab.rawValue)
              .font(GitHubTypography.body)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            viewModel.selectedTab == tab
              ? Color.accentColor.opacity(0.15)
              : Color.clear
          )
          .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
      }

      Spacer()

      // Refresh button
      Button {
        Task {
          switch viewModel.selectedTab {
          case .pullRequests: await viewModel.loadPullRequests()
          case .issues: await viewModel.loadIssues()
          }
        }
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  // MARK: - Current Branch PR Banner

  private func currentBranchPRBanner(_ pr: GitHubPullRequest) -> some View {
    Button {
      viewModel.selectPR(pr)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 11))
          .foregroundStyle(.blue)

        Text("Current branch:")
          .font(GitHubTypography.caption)
          .foregroundStyle(.secondary)

        Text("#\(pr.number)")
          .font(GitHubTypography.monoStrong)
          .foregroundStyle(.blue)

        Text(pr.title)
          .font(GitHubTypography.button)
          .lineLimit(1)

        Spacer()

        ciStatusBadge(pr.ciStatus)

        Image(systemName: "chevron.right")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(Color.blue.opacity(0.05))
    }
    .buttonStyle(.plain)
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
      .padding(.horizontal, 12)
      .padding(.vertical, 6)

      Divider()

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
          LazyVStack(spacing: 1) {
            ForEach(viewModel.pullRequests) { pr in
              GitHubPRRow(pr: pr) {
                viewModel.selectPR(pr)
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
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
      HStack(spacing: 4) {
        ForEach(GitHubIssueFilter.allCases) { filter in
          Button {
            viewModel.issueFilter = filter
            Task { await viewModel.loadIssues() }
          } label: {
            Text(filter.rawValue)
              .font(GitHubTypography.button)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(
                viewModel.issueFilter == filter
                  ? Color.secondary.opacity(0.2)
                  : Color.clear
              )
              .clipShape(RoundedRectangle(cornerRadius: 4))
          }
          .buttonStyle(.plain)
        }
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)

      Divider()

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
          LazyVStack(spacing: 1) {
            ForEach(viewModel.issues) { issue in
              GitHubIssueRow(issue: issue) {
                viewModel.selectIssue(issue)
              }
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
  }

  // MARK: - Shared Components

  private func ciStatusBadge(_ status: CIStatus) -> some View {
    HStack(spacing: 3) {
      Image(systemName: status.icon)
        .font(.system(size: 9))
      Text(status.rawValue.capitalized)
        .font(GitHubTypography.badge)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(ciStatusColor(status).opacity(0.15))
    .foregroundStyle(ciStatusColor(status))
    .clipShape(Capsule())
  }

  private func ciStatusColor(_ status: CIStatus) -> Color {
    switch status {
    case .success: return .green
    case .failure: return .red
    case .pending: return .orange
    case .none: return .secondary
    }
  }

  private func loadingView(_ message: String) -> some View {
    VStack(spacing: 12) {
      Spacer()
      ProgressView()
        .scaleEffect(0.8)
      Text(message)
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private func errorView(_ message: String, retry: @escaping () -> Void) -> some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 24))
        .foregroundStyle(.orange)
      Text(message)
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Retry") { retry() }
        .buttonStyle(.bordered)
        .controlSize(.small)
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding()
  }

  private func emptyView(_ title: String, _ message: String) -> some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "tray")
        .font(.system(size: 24))
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
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "terminal")
        .font(.system(size: 36))
        .foregroundStyle(.tertiary)

      Text("GitHub CLI Not Installed")
        .font(GitHubTypography.sectionTitle)

      Text("Install the GitHub CLI to use GitHub integration.\nRun: brew install gh")
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      HStack(spacing: 8) {
        Text("brew install gh")
          .font(GitHubTypography.monoBody)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.secondary.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .textSelection(.enabled)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding()
  }

  // MARK: - GH Not Authenticated

  private var ghNotAuthenticatedView: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "person.badge.key")
        .font(.system(size: 36))
        .foregroundStyle(.tertiary)

      Text("Not Authenticated")
        .font(GitHubTypography.sectionTitle)

      Text("Authenticate with GitHub CLI to access your repositories.")
        .font(GitHubTypography.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      HStack(spacing: 8) {
        Text("gh auth login")
          .font(GitHubTypography.monoBody)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(Color.secondary.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .textSelection(.enabled)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding()
  }
}

// MARK: - PR Row

struct GitHubPRRow: View {
  let pr: GitHubPullRequest
  let onSelect: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        // State icon
        Image(systemName: pr.stateIcon)
          .font(.system(size: 13))
          .foregroundStyle(prStateColor)
          .frame(width: 20)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text("#\(pr.number)")
              .font(GitHubTypography.monoStrong)
              .foregroundStyle(.secondary)

            Text(pr.title)
              .font(GitHubTypography.body)
              .lineLimit(1)
          }

          HStack(spacing: 8) {
            if let author = pr.author {
              Text(author.login)
                .font(GitHubTypography.caption)
                .foregroundStyle(.tertiary)
            }

            Text(pr.headRefName)
              .font(GitHubTypography.monoCaption)
              .foregroundStyle(.blue.opacity(0.8))
              .lineLimit(1)

            if let labels = pr.labels, !labels.isEmpty {
              ForEach(labels.prefix(2)) { label in
                Text(label.name)
                  .font(GitHubTypography.badge)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(labelColor(label).opacity(0.2))
                  .foregroundStyle(labelColor(label))
                  .clipShape(Capsule())
              }
            }
          }
        }

        Spacer()

        // Stats
        HStack(spacing: 8) {
          if pr.changedFiles > 0 {
            HStack(spacing: 2) {
              Image(systemName: "doc")
                .font(.system(size: 9))
              Text("\(pr.changedFiles)")
                .font(GitHubTypography.monoCaption)
            }
            .foregroundStyle(.secondary)
          }

          HStack(spacing: 4) {
            Text("+\(pr.additions)")
              .font(GitHubTypography.monoCaption)
              .foregroundStyle(.green)
            Text("-\(pr.deletions)")
              .font(GitHubTypography.monoCaption)
              .foregroundStyle(.red)
          }

          // Review decision
          if let decision = pr.reviewDecision {
            reviewBadge(decision)
          }

          // CI status
          ciIcon(pr.ciStatus)
        }

        Image(systemName: "chevron.right")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        (colorScheme == .dark ? Color(white: 0.06) : Color.white)
          .opacity(0.5)
      )
    }
    .buttonStyle(.plain)
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
    case .open: return pr.isDraft ? .secondary : .green
    case .closed: return .red
    case .merged: return .purple
    case .unknown: return .secondary
    }
  }

  private func reviewBadge(_ decision: String) -> some View {
    let (icon, color): (String, Color) = {
      switch GitHubReviewDecisionState(rawValue: decision) {
      case .approved: return ("checkmark.circle.fill", .green)
      case .changesRequested: return ("exclamationmark.circle.fill", .orange)
      case .reviewRequired: return ("eye.circle", .secondary)
      case .unknown: return ("minus.circle", .secondary)
      }
    }()

    return Image(systemName: icon)
      .font(.system(size: 12))
      .foregroundStyle(color)
  }

  private func ciIcon(_ status: CIStatus) -> some View {
    Image(systemName: status.icon)
      .font(.system(size: 10))
      .foregroundStyle(ciColor(status))
  }

  private func ciColor(_ status: CIStatus) -> Color {
    switch status {
    case .success: return .green
    case .failure: return .red
    case .pending: return .orange
    case .none: return .clear
    }
  }

  private func labelColor(_ label: GitHubLabel) -> Color {
    guard let hex = label.color else { return .secondary }
    return Color(hex: hex)
  }
}

// MARK: - Issue Row

struct GitHubIssueRow: View {
  let issue: GitHubIssue
  let onSelect: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        Image(systemName: issue.stateIcon)
          .font(.system(size: 13))
          .foregroundStyle(issueStateColor)
          .frame(width: 20)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text("#\(issue.number)")
              .font(GitHubTypography.monoStrong)
              .foregroundStyle(.secondary)

            Text(issue.title)
              .font(GitHubTypography.body)
              .lineLimit(1)
          }

          HStack(spacing: 8) {
            if let author = issue.author {
              Text(author.login)
                .font(GitHubTypography.caption)
                .foregroundStyle(.tertiary)
            }

            if let labels = issue.labels, !labels.isEmpty {
              ForEach(labels.prefix(3)) { label in
                Text(label.name)
                  .font(GitHubTypography.badge)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 1)
                  .background(Color.secondary.opacity(0.15))
                  .clipShape(Capsule())
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
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        (colorScheme == .dark ? Color(white: 0.06) : Color.white)
          .opacity(0.5)
      )
    }
    .buttonStyle(.plain)
  }

  private var issueStateColor: Color {
    switch issue.stateKind {
    case .open: return .green
    case .closed: return .purple
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
