//
//  GitHubPRDetailView.swift
//  AgentHub
//
//  Detailed view for a GitHub pull request with diff, comments, and actions
//

import AgentHubGitHub
import AppKit
import SwiftUI
import PierreDiffsSwift

// MARK: - PR Detail Tabs

enum PRDetailTab: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case files = "Files"
  case checks = "Checks"
  case comments = "Comments"

  var id: String { rawValue }

  var icon: String {
    switch self {
    case .overview: return "doc.text"
    case .files: return "doc.on.doc"
    case .checks: return "checkmark.shield"
    case .comments: return "bubble.left.and.bubble.right"
    }
  }
}

// MARK: - GitHubPRDetailView

struct GitHubPRDetailView: View {
  @Bindable var viewModel: GitHubViewModel
  let pr: GitHubPullRequest
  let session: CLISession?
  let onSendToSession: ((String, CLISession) -> Void)?

  @State private var selectedTab: PRDetailTab = .overview
  @State private var selectedFile: GitHubPRFile?
  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap
  @State private var parsedPRDiffsByFile: [String: String] = [:]
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      navigationHeader
      GradientDivider()
      prInfoHeader
      GradientDivider()
      detailTabBar
      GradientDivider()
      tabContent
    }
    .onAppear {
      syncSelectedFile()
      rebuildParsedPRDiffs()
    }
    .onChange(of: viewModel.selectedPRFiles) { _, _ in
      syncSelectedFile()
    }
    .onChange(of: viewModel.selectedPRDiff) { _, _ in
      rebuildParsedPRDiffs()
    }
  }

  // MARK: - Navigation Header

  private var navigationHeader: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button {
        viewModel.deselectPR()
      } label: {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Image(systemName: "chevron.left")
            .font(.system(size: 10, weight: .semibold))
          Text("Back")
            .font(GitHubTypography.body)
        }
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      Spacer()

      HStack(spacing: DesignTokens.Spacing.sm) {
        Button {
          if let url = URL(string: pr.url) {
            NSWorkspace.shared.open(url)
          }
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "safari")
              .font(.system(size: 10))
            Text("Open in Browser")
          }
        }
        .buttonStyle(.agentHubOutlined)

        Button {
          Task { await viewModel.checkoutPR() }
        } label: {
          HStack(spacing: 3) {
            checkoutIcon
            Text(checkoutButtonLabel)
          }
        }
        .buttonStyle(.agentHubOutlined(tint: checkoutTintColor))
        .disabled(viewModel.checkoutState == .loading)

        if let session, let onSendToSession {
          Button {
            let prompt = "Look at PR #\(pr.number) (\(pr.title)) on branch \(pr.headRefName). The PR has \(pr.additions) additions and \(pr.deletions) deletions across \(pr.changedFiles) files."
            onSendToSession(prompt, session)
          } label: {
            HStack(spacing: 3) {
              Image(systemName: "arrow.right.circle")
                .font(.system(size: 10))
              Text("Send to Session")
            }
          }
          .buttonStyle(.agentHubOutlined(tint: Color.brandPrimary))
        }
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
  }

  @ViewBuilder
  private var checkoutIcon: some View {
    switch viewModel.checkoutState {
    case .loading:
      ProgressView()
        .controlSize(.mini)
        .frame(width: 10, height: 10)
    case .success:
      Image(systemName: "checkmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(GitHubPalette.addition)
    case .error:
      Image(systemName: "xmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(GitHubPalette.deletion)
    case .idle:
      Image(systemName: "arrow.down.to.line")
        .font(.system(size: 10))
    }
  }

  private var checkoutButtonLabel: String {
    switch viewModel.checkoutState {
    case .idle: return "Checkout"
    case .loading: return "Checking out..."
    case .success: return "Checked out"
    case .error: return "Failed"
    }
  }

  private var checkoutTintColor: Color {
    switch viewModel.checkoutState {
    case .success: return .green
    case .error: return .red
    default: return .secondary
    }
  }

  // MARK: - PR Info Header

  private var prInfoHeader: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      // State + number row
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: pr.stateIcon)
          .font(.system(size: 14))
          .foregroundStyle(prStateColor)

        Text("#\(pr.number)")
          .font(GitHubTypography.monoTitle)
          .foregroundStyle(Color.brandPrimary)

        if pr.isDraft {
          Text("Draft")
            .font(GitHubTypography.badge)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
        }
      }

      Text(pr.title)
        .font(GitHubTypography.sectionTitle)
        .fixedSize(horizontal: false, vertical: true)

      // Metadata row
      HStack(spacing: DesignTokens.Spacing.md) {
        if let author = pr.author {
          HStack(spacing: DesignTokens.Spacing.xs) {
            AuthorAvatarView(login: author.login, size: 18)
            Text(author.login)
              .font(GitHubTypography.bodySmall)
          }
          .foregroundStyle(.secondary)
        }

        HStack(spacing: DesignTokens.Spacing.xs) {
          BranchBadge(name: pr.headRefName)
          Image(systemName: "arrow.right")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
          BranchBadge(name: pr.baseRefName)
        }

        AdditionsDeletionsBadge(additions: pr.additions, deletions: pr.deletions)

        Text("\(pr.changedFiles) files")
          .font(GitHubTypography.bodySmall)
          .foregroundStyle(.secondary)

        if let decision = pr.reviewDecision {
          ReviewDecisionBadge(decision: decision)
        }
      }

      if let labels = pr.labels, !labels.isEmpty {
        HStack(spacing: DesignTokens.Spacing.xs) {
          ForEach(labels) { label in
            GitHubLabelPill(label: label)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
  }

  private var prStateColor: Color {
    switch pr.stateKind {
    case .open: return pr.isDraft ? .secondary : .green
    case .closed: return .red
    case .merged: return .purple
    case .unknown: return .secondary
    }
  }

  // MARK: - Tab Bar

  private var detailTabBar: some View {
    GitHubUnderlineTabBar(
      tabs: PRDetailTab.allCases,
      selected: $selectedTab,
      icon: { $0.icon },
      title: { $0.rawValue },
      badge: { tab in
        switch tab {
        case .comments: return pr.comments?.count
        case .files: return pr.changedFiles > 0 ? pr.changedFiles : nil
        default: return nil
        }
      },
      onSelect: { tab in
        if tab == .checks && viewModel.loadedChecksPRNumber != pr.number {
          Task { await viewModel.loadChecks(prNumber: pr.number) }
        }
      }
    )
  }

  // MARK: - Tab Content

  @ViewBuilder
  private var tabContent: some View {
    switch selectedTab {
    case .overview:
      overviewTab
    case .files:
      filesTab
    case .checks:
      checksTab
    case .comments:
      commentsTab
    }
  }

  // MARK: - Overview Tab

  private var overviewTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        if let body = pr.body, !body.isEmpty {
          MarkdownCardView(content: body)
        } else {
          Text("No description provided.")
            .font(GitHubTypography.body)
            .foregroundStyle(.tertiary)
            .italic()
        }

        // Details card
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
          HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "doc.text")
              .font(.system(size: 11))
              .foregroundStyle(Color.brandPrimary)
            Text("Details")
              .font(GitHubTypography.sectionLabel)
          }

          VStack(spacing: 0) {
            detailRow("Mergeable", value: pr.mergeabilityKind?.displayName ?? "Unknown", icon: mergeableIcon)
            detailDivider
            if let created = pr.createdAt {
              detailRow("Created", value: relativeTime(created))
              detailDivider
            }
            if let updated = pr.updatedAt {
              detailRow("Updated", value: relativeTime(updated))
              detailDivider
            }
            if let reviewRequests = pr.reviewRequests, !reviewRequests.isEmpty {
              reviewersRow(reviewRequests)
            }
          }
        }
        .padding(DesignTokens.Spacing.md)
        .agentHubCard()
      }
      .padding(DesignTokens.Spacing.md)
    }
  }

  private var mergeableIcon: String? {
    switch pr.mergeabilityKind {
    case .mergeable: return "checkmark.circle.fill"
    case .conflicting: return "exclamationmark.triangle.fill"
    default: return nil
    }
  }

  private func detailRow(_ label: String, value: String, icon: String? = nil) -> some View {
    HStack {
      Text(label)
        .font(GitHubTypography.button)
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
      if let icon {
        Image(systemName: icon)
          .font(.system(size: 10))
          .foregroundStyle(icon.contains("checkmark") ? .green : .orange)
      }
      Text(value)
        .font(GitHubTypography.bodySmall)
        .foregroundStyle(.primary)
      Spacer()
    }
    .padding(.vertical, DesignTokens.Spacing.xs)
  }

  private func reviewersRow(_ requests: [GitHubReviewRequest]) -> some View {
    HStack {
      Text("Reviewers")
        .font(GitHubTypography.button)
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
      HStack(spacing: DesignTokens.Spacing.xs) {
        ForEach(requests.prefix(5), id: \.login) { request in
          if let login = request.login {
            AuthorAvatarView(login: login, size: 20)
              .help(login)
          } else if let slug = request.slug {
            Text(slug)
              .font(GitHubTypography.bodySmall)
          }
        }
      }
      Spacer()
    }
    .padding(.vertical, DesignTokens.Spacing.xs)
  }

  private var detailDivider: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.1))
      .frame(height: 0.5)
  }

  // MARK: - Files Tab

  private var filesTab: some View {
    Group {
      if viewModel.selectedPRFiles.isEmpty && viewModel.prDetailLoadingState == .loading {
        ProgressView("Loading files...")
          .tint(Color.brandPrimary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.selectedPRFiles.isEmpty {
        Text("No files changed")
          .font(GitHubTypography.body)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HSplitView {
          fileList
          diffPane
        }
      }
    }
  }

  private var fileList: some View {
    ScrollView {
      LazyVStack(spacing: 1) {
        ForEach(viewModel.selectedPRFiles) { file in
          FileListRow(
            file: file,
            isSelected: selectedFile?.id == file.id
          ) {
            selectedFile = file
          }
        }
      }
    }
    .frame(minWidth: 200, idealWidth: 280, maxWidth: 350)
  }

  @ViewBuilder
  private var diffPane: some View {
    if let file = selectedFile, let renderedDiff = renderedDiff(for: file) {
      VStack(spacing: 0) {
        diffHeader(for: file)
        Divider()
        PierreDiffView(
          oldContent: renderedDiff.oldContent,
          newContent: renderedDiff.newContent,
          fileName: (file.filename as NSString).lastPathComponent,
          diffStyle: $diffStyle,
          overflowMode: $overflowMode
        )
      }
      .background(colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.98))
    } else if let file = selectedFile {
      VStack {
        Spacer()
        Text("No diff available for \(file.filename)")
          .font(GitHubTypography.body)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .frame(maxWidth: .infinity)
    } else {
      VStack {
        Spacer()
        Text("Select a file to view its diff")
          .font(GitHubTypography.body)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .frame(maxWidth: .infinity)
    }
  }

  private func diffHeader(for file: GitHubPRFile) -> some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: file.statusIcon)
          .font(.system(size: 11))
          .foregroundStyle(fileStatusColor(file.status))

        Text(file.filename)
          .font(GitHubTypography.monoBody)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer()

      AdditionsDeletionsBadge(additions: file.additions, deletions: file.deletions)

      HStack(spacing: DesignTokens.Spacing.sm) {
        Button {
          diffStyle = diffStyle == .split ? .unified : .split
        } label: {
          Image(systemName: diffStyle == .split ? "rectangle.split.2x1" : "rectangle.stack")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(diffStyle == .split ? "Switch to unified view" : "Switch to split view")

        Button {
          overflowMode = overflowMode == .wrap ? .scroll : .wrap
        } label: {
          Image(systemName: overflowMode == .wrap ? "text.alignleft" : "text.aligncenter")
            .font(.system(size: 12))
            .foregroundStyle(overflowMode == .wrap ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .help(overflowMode == .wrap ? "Disable word wrap" : "Enable word wrap")
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
  }

  private func fileStatusColor(_ status: String) -> Color {
    switch status {
    case "added": return .green
    case "removed": return .red
    case "modified": return .orange
    case "renamed": return .blue
    default: return .secondary
    }
  }

  private func syncSelectedFile() {
    guard !viewModel.selectedPRFiles.isEmpty else {
      selectedFile = nil
      return
    }

    guard let selectedFile else {
      self.selectedFile = viewModel.selectedPRFiles.first
      return
    }

    if !viewModel.selectedPRFiles.contains(where: { $0.id == selectedFile.id }) {
      self.selectedFile = viewModel.selectedPRFiles.first
    }
  }

  private func rebuildParsedPRDiffs() {
    guard !viewModel.selectedPRDiff.isEmpty else {
      parsedPRDiffsByFile = [:]
      return
    }

    let parsedDiffs = DiffParserUtils.parse(diffOutput: viewModel.selectedPRDiff)
    parsedPRDiffsByFile = Dictionary(
      parsedDiffs.map { ($0.filePath, $0.diffContent) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  private func renderedDiff(for file: GitHubPRFile) -> GitHubRenderedDiff? {
    if let patch = file.patch,
       let rendered = GitHubDiffRenderAdapter.renderedDiff(from: patch) {
      return rendered
    }

    if let fallbackPatch = parsedPRDiffsByFile[file.filename] {
      return GitHubDiffRenderAdapter.renderedDiff(from: fallbackPatch)
    }

    return nil
  }

  // MARK: - Checks Tab

  private var checksTab: some View {
    Group {
      switch viewModel.checksLoadingState {
      case .loading:
        ProgressView("Loading checks...")
          .tint(Color.brandPrimary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .error(let msg):
        VStack(spacing: DesignTokens.Spacing.sm) {
          Spacer()
          Text("Failed to load checks")
            .font(GitHubTypography.sectionTitle)
          Text(msg)
            .font(GitHubTypography.bodySmall)
            .foregroundStyle(.secondary)
          Button("Retry") {
            Task { await viewModel.loadChecks(prNumber: pr.number) }
          }
          .buttonStyle(.agentHubOutlined(tint: .orange))
          Spacer()
        }
        .frame(maxWidth: .infinity)
      default:
        if viewModel.checks.isEmpty {
          VStack {
            Spacer()
            Image(systemName: "checkmark.shield")
              .font(.system(size: 28))
              .foregroundStyle(.tertiary)
            Text("No CI checks configured")
              .font(GitHubTypography.body)
              .foregroundStyle(.secondary)
            Spacer()
          }
          .frame(maxWidth: .infinity)
        } else {
          checksContent
        }
      }
    }
    .task {
      if viewModel.loadedChecksPRNumber != pr.number {
        await viewModel.loadChecks(prNumber: pr.number)
      }
    }
  }

  private var checksContent: some View {
    VStack(spacing: 0) {
      // Summary banner
      checksSummaryBanner

      ScrollView {
        LazyVStack(spacing: DesignTokens.Spacing.xs) {
          ForEach(sortedChecks) { check in
            CheckRunRow(check: check)
          }
        }
        .padding(DesignTokens.Spacing.md)
      }
    }
  }

  private var checksSummaryBanner: some View {
    let passed = viewModel.checks.filter { $0.ciStatus == .success }.count
    let failed = viewModel.checks.filter { $0.ciStatus == .failure }.count
    let pending = viewModel.checks.filter { $0.ciStatus == .pending }.count

    return HStack(spacing: DesignTokens.Spacing.md) {
      if passed > 0 {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(GitHubPalette.addition)
          Text("\(passed) passed")
            .font(GitHubTypography.bodySmall)
            .foregroundStyle(GitHubPalette.addition)
        }
      }
      if failed > 0 {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(GitHubPalette.deletion)
          Text("\(failed) failed")
            .font(GitHubTypography.bodySmall)
            .foregroundStyle(GitHubPalette.deletion)
        }
      }
      if pending > 0 {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Image(systemName: "clock.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
          Text("\(pending) pending")
            .font(GitHubTypography.bodySmall)
            .foregroundStyle(.orange)
        }
      }
      Spacer()
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.97))
  }

  private var sortedChecks: [GitHubCheckRun] {
    viewModel.checks.sorted { a, b in
      let order: (CIStatus) -> Int = { status in
        switch status {
        case .failure: return 0
        case .pending: return 1
        case .success: return 2
        case .none: return 3
        }
      }
      return order(a.ciStatus) < order(b.ciStatus)
    }
  }

  // MARK: - Comments Tab

  private var commentsTab: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: DesignTokens.Spacing.sm) {
          // PR body comments
          if let comments = pr.comments {
            ForEach(comments) { comment in
              GitHubCommentCard(
                author: comment.author,
                createdAt: comment.createdAt,
                commentBody: comment.body
              )
            }
          }

          // Review comments
          if !viewModel.selectedPRReviewComments.isEmpty {
            GradientDivider()
              .padding(.vertical, DesignTokens.Spacing.xs)

            HStack(spacing: DesignTokens.Spacing.xs) {
              Image(systemName: "text.bubble")
                .font(.system(size: 11))
                .foregroundStyle(Color.brandPrimary)
              Text("Review Comments")
                .font(GitHubTypography.sectionLabel)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(viewModel.selectedPRReviewComments) { comment in
              reviewCommentCard(comment)
            }
          }

          if (pr.comments ?? []).isEmpty && viewModel.selectedPRReviewComments.isEmpty {
            VStack(spacing: DesignTokens.Spacing.sm) {
              Spacer()
              Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
              Text("No comments yet")
                .font(GitHubTypography.body)
                .foregroundStyle(.secondary)
              Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 100)
          }
        }
        .padding(DesignTokens.Spacing.md)
      }

      GradientDivider()

      GitHubCommentInput(
        text: $viewModel.newCommentText,
        isSubmitting: viewModel.isSubmittingComment
      ) {
        Task { await viewModel.submitPRComment() }
      }
    }
  }

  private func reviewCommentCard(_ comment: GitHubComment) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        if let author = comment.author {
          AuthorAvatarView(login: author.login, size: 20)
          Text(author.login)
            .font(GitHubTypography.sectionLabel)
        }
        if let path = comment.path {
          Text(path)
            .font(GitHubTypography.monoCaption)
            .foregroundStyle(.blue)
            .lineLimit(1)
        }
        if let line = comment.line {
          Text("L\(line)")
            .font(GitHubTypography.monoCaption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let created = comment.createdAt {
          Text(relativeTime(created))
            .font(GitHubTypography.caption)
            .foregroundStyle(.tertiary)
        }
      }

      if let hunk = comment.diffHunk {
        Text(hunk.components(separatedBy: "\n").suffix(3).joined(separator: "\n"))
          .font(GitHubTypography.monoCaption)
          .foregroundStyle(.secondary)
          .padding(DesignTokens.Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
              .fill(colorScheme == .dark ? Color(white: 0.04) : Color(white: 0.93))
          )
      }

      Text(comment.body)
        .font(GitHubTypography.body)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(DesignTokens.Spacing.md)
    .agentHubCard()
  }
}

// MARK: - File List Row

private struct FileListRow: View {
  let file: GitHubPRFile
  let isSelected: Bool
  let onSelect: () -> Void

  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 0) {
        if isSelected {
          Rectangle()
            .fill(Color.brandPrimary)
            .frame(width: 2)
        }

        HStack(spacing: DesignTokens.Spacing.sm) {
          Image(systemName: file.statusIcon)
            .font(.system(size: 10))
            .foregroundStyle(fileStatusColor)
            .frame(width: 16)

          Text(file.filename)
            .font(GitHubTypography.monoBody)
            .lineLimit(1)
            .truncationMode(.middle)

          Spacer()

          AdditionsDeletionsBadge(additions: file.additions, deletions: file.deletions)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 5)
      }
      .background(rowBackground)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeInOut(duration: 0.1), value: isHovered)
  }

  private var rowBackground: Color {
    if isSelected {
      return Color.brandPrimary.opacity(0.1)
    }
    if isHovered {
      return colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96)
    }
    return Color.clear
  }

  private var fileStatusColor: Color {
    switch file.status {
    case "added": return .green
    case "removed": return .red
    case "modified": return .orange
    case "renamed": return .blue
    default: return .secondary
    }
  }
}

// MARK: - Check Run Row

private struct CheckRunRow: View {
  let check: GitHubCheckRun

  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Image(systemName: check.statusIcon)
        .font(.system(size: 13))
        .foregroundStyle(checkColor)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 1) {
        Text(check.name)
          .font(GitHubTypography.body)

        Text(check.statusDisplayName)
          .font(GitHubTypography.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      CIStatusBadge(status: check.ciStatus)
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
        .fill(isHovered
          ? (colorScheme == .dark ? Color(white: 0.10) : Color(white: 0.96))
          : (colorScheme == .dark ? Color(white: 0.07) : Color(white: 0.98))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous)
        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: AgentHubLayout.rowCornerRadius, style: .continuous))
    .onHover { isHovered = $0 }
    .animation(.easeInOut(duration: 0.15), value: isHovered)
    .onTapGesture {
      if let url = check.detailsUrl.flatMap(URL.init(string:)) {
        NSWorkspace.shared.open(url)
      }
    }
  }

  private var checkColor: Color {
    switch check.ciStatus {
    case .success: return .green
    case .failure: return .red
    case .pending: return .orange
    case .none: return .secondary
    }
  }
}
