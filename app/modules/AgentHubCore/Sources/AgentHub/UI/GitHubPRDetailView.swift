//
//  GitHubPRDetailView.swift
//  AgentHub
//
//  Detailed view for a GitHub pull request with diff, comments, and actions
//

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
  @State private var showingReviewSheet = false
  @State private var diffStyle: DiffStyle = .unified
  @State private var overflowMode: OverflowMode = .wrap
  @State private var parsedPRDiffsByFile: [String: String] = [:]
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      // Navigation header
      navigationHeader

      Divider()

      // PR info header
      prInfoHeader

      Divider()

      // Tab bar
      tabBar

      Divider()

      // Tab content
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
    HStack(spacing: 8) {
      Button {
        viewModel.deselectPR()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left")
            .font(.system(size: 10, weight: .semibold))
          Text("Back")
            .font(GitHubTypography.body)
        }
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      Spacer()

      // Action buttons
      HStack(spacing: 6) {
        Button {
          if let url = URL(string: pr.url) {
            NSWorkspace.shared.open(url)
          }
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "safari")
              .font(.system(size: 10))
            Text("Open in Browser")
              .font(GitHubTypography.button)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.secondary.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)

        Button {
          Task { await viewModel.checkoutPR() }
        } label: {
          HStack(spacing: 3) {
            switch viewModel.checkoutState {
            case .loading:
              ProgressView()
                .controlSize(.mini)
                .frame(width: 10, height: 10)
            case .success:
              Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.green)
            case .error:
              Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
            case .idle:
              Image(systemName: "arrow.down.to.line")
                .font(.system(size: 10))
            }
            Text(checkoutButtonLabel)
              .font(GitHubTypography.button)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(checkoutButtonBackground)
          .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.checkoutState == .loading)

        Button {
          showingReviewSheet = true
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "eye")
              .font(.system(size: 10))
            Text("Review")
              .font(GitHubTypography.button)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.green.opacity(0.15))
          .foregroundStyle(.green)
          .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)

        if let session, let onSendToSession {
          Button {
            let prompt = "Look at PR #\(pr.number) (\(pr.title)) on branch \(pr.headRefName). The PR has \(pr.additions) additions and \(pr.deletions) deletions across \(pr.changedFiles) files."
            onSendToSession(prompt, session)
          } label: {
            HStack(spacing: 3) {
              Image(systemName: "arrow.right.circle")
                .font(.system(size: 10))
              Text("Send to Session")
                .font(GitHubTypography.button)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.15))
            .foregroundStyle(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 5))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  private var checkoutButtonLabel: String {
    switch viewModel.checkoutState {
    case .idle: return "Checkout"
    case .loading: return "Checking out..."
    case .success: return "Checked out"
    case .error: return "Failed"
    }
  }

  private var checkoutButtonBackground: Color {
    switch viewModel.checkoutState {
    case .success: return Color.green.opacity(0.15)
    case .error: return Color.red.opacity(0.15)
    default: return Color.secondary.opacity(0.1)
    }
  }

  // MARK: - PR Info Header

  private var prInfoHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: pr.stateIcon)
          .font(.system(size: 14))
          .foregroundStyle(prStateColor)

        Text("#\(pr.number)")
          .font(GitHubTypography.monoTitle)

        if pr.isDraft {
          Text("Draft")
            .font(GitHubTypography.badge)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
        }
      }

      Text(pr.title)
        .font(GitHubTypography.sectionTitle)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        if let author = pr.author {
          HStack(spacing: 3) {
            Image(systemName: "person")
              .font(.system(size: 9))
            Text(author.login)
              .font(GitHubTypography.bodySmall)
          }
          .foregroundStyle(.secondary)
        }

        HStack(spacing: 3) {
          Text(pr.headRefName)
            .font(GitHubTypography.monoCaption)
            .foregroundStyle(.blue)
          Image(systemName: "arrow.right")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
          Text(pr.baseRefName)
            .font(GitHubTypography.monoCaption)
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 6) {
          Text("+\(pr.additions)")
            .font(GitHubTypography.monoBody)
            .foregroundStyle(.green)
          Text("-\(pr.deletions)")
            .font(GitHubTypography.monoBody)
            .foregroundStyle(.red)
          Text("\(pr.changedFiles) files")
            .font(GitHubTypography.bodySmall)
            .foregroundStyle(.secondary)
        }

        if let decision = pr.reviewDecision {
          reviewDecisionBadge(decision)
        }
      }

      if let labels = pr.labels, !labels.isEmpty {
        HStack(spacing: 4) {
          ForEach(labels) { label in
            Text(label.name)
              .font(GitHubTypography.badge)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.12))
              .clipShape(Capsule())
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var prStateColor: Color {
    switch pr.stateKind {
    case .open: return pr.isDraft ? .secondary : .green
    case .closed: return .red
    case .merged: return .purple
    case .unknown: return .secondary
    }
  }

  private func reviewDecisionBadge(_ decision: String) -> some View {
    let (label, color): (String, Color) = {
      switch GitHubReviewDecisionState(rawValue: decision) {
      case .approved: return ("Approved", .green)
      case .changesRequested: return ("Changes Requested", .orange)
      case .reviewRequired: return ("Review Required", .secondary)
      case .unknown(let rawValue): return (rawValue, .secondary)
      }
    }()

    return Text(label)
      .font(GitHubTypography.badge)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.15))
      .foregroundStyle(color)
      .clipShape(Capsule())
  }

  // MARK: - Tab Bar

  private var tabBar: some View {
    HStack(spacing: 2) {
      ForEach(PRDetailTab.allCases) { tab in
        Button {
          selectedTab = tab
          if tab == .checks && viewModel.loadedChecksPRNumber != pr.number {
            Task { await viewModel.loadChecks(prNumber: pr.number) }
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: tab.icon)
              .font(.system(size: 10))
            Text(tab.rawValue)
              .font(GitHubTypography.button)

            // Badge counts
            if tab == .comments, let comments = pr.comments, !comments.isEmpty {
              Text("\(comments.count)")
                .font(GitHubTypography.monoCaption)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.2))
                .clipShape(Capsule())
            }
            if tab == .files {
              Text("\(pr.changedFiles)")
                .font(GitHubTypography.monoCaption)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.2))
                .clipShape(Capsule())
            }
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            selectedTab == tab
              ? Color.accentColor.opacity(0.12)
              : Color.clear
          )
          .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
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
      VStack(alignment: .leading, spacing: 12) {
        if let body = pr.body, !body.isEmpty {
          MarkdownCardView(content: body)
        } else {
          Text("No description provided.")
            .font(GitHubTypography.body)
            .foregroundStyle(.tertiary)
            .italic()
        }

        // Quick stats
        VStack(alignment: .leading, spacing: 8) {
          Text("Details")
            .font(GitHubTypography.sectionLabel)

          detailRow("Mergeable", value: pr.mergeabilityKind?.displayName ?? "Unknown")
          if let created = pr.createdAt {
            detailRow("Created", value: relativeTime(created))
          }
          if let updated = pr.updatedAt {
            detailRow("Updated", value: relativeTime(updated))
          }
          if let reviewRequests = pr.reviewRequests, !reviewRequests.isEmpty {
            detailRow("Reviewers", value: reviewRequests.compactMap { $0.login ?? $0.slug }.joined(separator: ", "))
          }
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
        )
      }
      .padding(12)
    }
  }

  private func detailRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label)
        .font(GitHubTypography.button)
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
      Text(value)
        .font(GitHubTypography.bodySmall)
        .foregroundStyle(.primary)
      Spacer()
    }
  }

  // MARK: - Files Tab

  private var filesTab: some View {
    Group {
      if viewModel.selectedPRFiles.isEmpty && viewModel.prDetailLoadingState == .loading {
        ProgressView("Loading files...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.selectedPRFiles.isEmpty {
        Text("No files changed")
          .font(GitHubTypography.body)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HSplitView {
          // File list
          ScrollView {
            LazyVStack(spacing: 1) {
              ForEach(viewModel.selectedPRFiles) { file in
                Button {
                  selectedFile = file
                } label: {
                  HStack(spacing: 6) {
                    Image(systemName: file.statusIcon)
                      .font(.system(size: 10))
                      .foregroundStyle(fileStatusColor(file.status))
                      .frame(width: 16)

                    Text(file.filename)
                      .font(GitHubTypography.monoBody)
                      .lineLimit(1)
                      .truncationMode(.middle)

                    Spacer()

                    HStack(spacing: 4) {
                      Text("+\(file.additions)")
                        .font(GitHubTypography.monoCaption)
                        .foregroundStyle(.green)
                      Text("-\(file.deletions)")
                        .font(GitHubTypography.monoCaption)
                        .foregroundStyle(.red)
                    }
                  }
                  .padding(.horizontal, 8)
                  .padding(.vertical, 5)
                  .background(
                    selectedFile?.id == file.id
                      ? Color.accentColor.opacity(0.1)
                      : Color.clear
                  )
                }
                .buttonStyle(.plain)
              }
            }
          }
          .frame(minWidth: 200, idealWidth: 280, maxWidth: 350)

          // Diff content
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
      }
    }
  }

  private func diffHeader(for file: GitHubPRFile) -> some View {
    HStack(spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: file.statusIcon)
          .font(.system(size: 11))
          .foregroundStyle(fileStatusColor(file.status))

        Text(file.filename)
          .font(GitHubTypography.monoBody)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Spacer()

      HStack(spacing: 6) {
        Text("+\(file.additions)")
          .font(GitHubTypography.monoCaption)
          .foregroundStyle(.green)
        Text("-\(file.deletions)")
          .font(GitHubTypography.monoCaption)
          .foregroundStyle(.red)
      }

      HStack(spacing: 8) {
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
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
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
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .error(let msg):
        VStack(spacing: 8) {
          Spacer()
          Text("Failed to load checks")
            .font(GitHubTypography.sectionTitle)
          Text(msg)
            .font(GitHubTypography.bodySmall)
            .foregroundStyle(.secondary)
          Button("Retry") {
            Task { await viewModel.loadChecks(prNumber: pr.number) }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          Spacer()
        }
        .frame(maxWidth: .infinity)
      default:
        if viewModel.checks.isEmpty {
          VStack {
            Spacer()
            Image(systemName: "checkmark.shield")
              .font(.system(size: 24))
              .foregroundStyle(.tertiary)
            Text("No CI checks configured")
              .font(GitHubTypography.body)
              .foregroundStyle(.secondary)
            Spacer()
          }
          .frame(maxWidth: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(viewModel.checks) { check in
                HStack(spacing: 8) {
                  Image(systemName: check.statusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(checkColor(check))
                    .frame(width: 20)

                  VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                      .font(GitHubTypography.body)

                    HStack(spacing: 4) {
                      Text(check.statusDisplayName)
                        .font(GitHubTypography.caption)
                        .foregroundStyle(.secondary)
                    }
                  }

                  Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
              }
            }
            .padding(.vertical, 8)
          }
        }
      }
    }
    .task {
      if viewModel.loadedChecksPRNumber != pr.number {
        await viewModel.loadChecks(prNumber: pr.number)
      }
    }
  }

  private func checkColor(_ check: GitHubCheckRun) -> Color {
    switch check.ciStatus {
    case .success: return .green
    case .failure: return .red
    case .pending: return .orange
    case .none: return .secondary
    }
  }

  // MARK: - Comments Tab

  private var commentsTab: some View {
    VStack(spacing: 0) {
      // Comments list
      ScrollView {
        LazyVStack(spacing: 8) {
          // PR body comments
          if let comments = pr.comments {
            ForEach(comments) { comment in
              commentCard(comment)
            }
          }

          // Review comments
          if !viewModel.selectedPRReviewComments.isEmpty {
            Divider()
              .padding(.vertical, 4)

            Text("Review Comments")
              .font(GitHubTypography.sectionLabel)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)

            ForEach(viewModel.selectedPRReviewComments) { comment in
              reviewCommentCard(comment)
            }
          }

          if (pr.comments ?? []).isEmpty && viewModel.selectedPRReviewComments.isEmpty {
            VStack(spacing: 8) {
              Spacer()
              Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
              Text("No comments yet")
                .font(GitHubTypography.body)
                .foregroundStyle(.secondary)
              Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 100)
          }
        }
        .padding(12)
      }

      Divider()

      // New comment input
      commentInput
    }
  }

  private func commentCard(_ comment: GitHubComment) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if let author = comment.author {
          Text(author.login)
            .font(GitHubTypography.sectionLabel)
        }
        if let created = comment.createdAt {
          Text(relativeTime(created))
            .font(GitHubTypography.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
      }

      Text(comment.body)
        .font(GitHubTypography.body)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
    )
  }

  private func reviewCommentCard(_ comment: GitHubComment) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if let author = comment.author {
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
          .padding(6)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(colorScheme == .dark ? Color(white: 0.04) : Color(white: 0.93))
          )
      }

      Text(comment.body)
        .font(GitHubTypography.body)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
    )
  }

  private var commentInput: some View {
    HStack(spacing: 8) {
      TextField("Add a comment...", text: $viewModel.newCommentText, axis: .vertical)
        .font(GitHubTypography.body)
        .textFieldStyle(.plain)
        .submitLabel(.send)
        .onSubmit(submitComment)
        .lineLimit(1...4)
        .padding(8)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )

      Button {
        submitComment()
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 20))
          .foregroundStyle(viewModel.newCommentText.isEmpty ? Color.secondary : Color.accentColor)
      }
      .buttonStyle(.plain)
      .disabled(viewModel.newCommentText.isEmpty || viewModel.isSubmittingComment)
    }
    .padding(10)
    .sheet(isPresented: $showingReviewSheet) {
      GitHubReviewSheet(viewModel: viewModel, pr: pr)
    }
  }

  private func submitComment() {
    Task { await viewModel.submitPRComment() }
  }
}

// MARK: - Review Sheet

struct GitHubReviewSheet: View {
  @Bindable var viewModel: GitHubViewModel
  let pr: GitHubPullRequest
  @Environment(\.dismiss) private var dismiss
  @State private var selectedEvent: GitHubReviewInput.Event = .comment

  var body: some View {
    VStack(spacing: 16) {
      Text("Review PR #\(pr.number)")
        .font(GitHubTypography.sectionTitle)

      Picker("Review Type", selection: $selectedEvent) {
        Text("Comment").tag(GitHubReviewInput.Event.comment)
        Text("Approve").tag(GitHubReviewInput.Event.approve)
        Text("Request Changes").tag(GitHubReviewInput.Event.requestChanges)
      }
      .pickerStyle(.segmented)

      TextEditor(text: $viewModel.reviewBody)
        .font(GitHubTypography.body)
        .frame(minHeight: 100)
        .padding(4)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )

      HStack {
        Button("Cancel") {
          dismiss()
        }
        .buttonStyle(.bordered)

        Spacer()

        Button {
          Task {
            await viewModel.submitReview(event: selectedEvent)
            dismiss()
          }
        } label: {
          Text("Submit Review")
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.isSubmittingReview)
      }
    }
    .padding(20)
    .frame(width: 450, height: 300)
  }
}
