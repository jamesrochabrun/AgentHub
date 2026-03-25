//
//  GitHubPRDetailView.swift
//  AgentHub
//
//  Detailed view for a GitHub pull request with diff, comments, and actions
//

import SwiftUI

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
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)

      Spacer()

      // Action buttons
      HStack(spacing: 6) {
        Button {
          Task { await viewModel.checkoutPR() }
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "arrow.down.to.line")
              .font(.system(size: 10))
            Text("Checkout")
              .font(.system(size: 11, weight: .medium))
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.secondary.opacity(0.1))
          .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)

        Button {
          showingReviewSheet = true
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "eye")
              .font(.system(size: 10))
            Text("Review")
              .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 11, weight: .medium))
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

  // MARK: - PR Info Header

  private var prInfoHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: pr.stateIcon)
          .font(.system(size: 14))
          .foregroundStyle(prStateColor)

        Text("#\(pr.number)")
          .font(.system(size: 13, weight: .bold, design: .monospaced))

        if pr.isDraft {
          Text("Draft")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
        }
      }

      Text(pr.title)
        .font(.system(size: 14, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        if let author = pr.author {
          HStack(spacing: 3) {
            Image(systemName: "person")
              .font(.system(size: 9))
            Text(author.login)
              .font(.system(size: 11))
          }
          .foregroundStyle(.secondary)
        }

        HStack(spacing: 3) {
          Text(pr.headRefName)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.blue)
          Image(systemName: "arrow.right")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
          Text(pr.baseRefName)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 6) {
          Text("+\(pr.additions)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.green)
          Text("-\(pr.deletions)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.red)
          Text("\(pr.changedFiles) files")
            .font(.system(size: 11))
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
              .font(.system(size: 10, weight: .medium))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.12))
              .clipShape(Capsule())
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var prStateColor: Color {
    switch pr.state.uppercased() {
    case "OPEN": return pr.isDraft ? .secondary : .green
    case "CLOSED": return .red
    case "MERGED": return .purple
    default: return .secondary
    }
  }

  private func reviewDecisionBadge(_ decision: String) -> some View {
    let (label, color): (String, Color) = {
      switch decision.uppercased() {
      case "APPROVED": return ("Approved", .green)
      case "CHANGES_REQUESTED": return ("Changes Requested", .orange)
      case "REVIEW_REQUIRED": return ("Review Required", .secondary)
      default: return (decision, .secondary)
      }
    }()

    return Text(label)
      .font(.system(size: 10, weight: .medium))
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
          if tab == .checks && viewModel.checks.isEmpty {
            Task { await viewModel.loadChecks(prNumber: pr.number) }
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: tab.icon)
              .font(.system(size: 10))
            Text(tab.rawValue)
              .font(.system(size: 11, weight: .medium))

            // Badge counts
            if tab == .comments, let comments = pr.comments, !comments.isEmpty {
              Text("\(comments.count)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.2))
                .clipShape(Capsule())
            }
            if tab == .files {
              Text("\(pr.changedFiles)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
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
          Text(body)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
            )
        } else {
          Text("No description provided.")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .italic()
        }

        // Quick stats
        VStack(alignment: .leading, spacing: 8) {
          Text("Details")
            .font(.system(size: 12, weight: .semibold))

          detailRow("Mergeable", value: pr.mergeable ?? "Unknown")
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
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 100, alignment: .leading)
      Text(value)
        .font(.system(size: 11))
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
          .font(.system(size: 12))
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
                      .font(.system(size: 11, design: .monospaced))
                      .lineLimit(1)
                      .truncationMode(.middle)

                    Spacer()

                    HStack(spacing: 4) {
                      Text("+\(file.additions)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                      Text("-\(file.deletions)")
                        .font(.system(size: 10, design: .monospaced))
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
          if let file = selectedFile, let patch = file.patch {
            ScrollView {
              Text(patch)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(colorScheme == .dark ? Color(white: 0.06) : Color(white: 0.98))
          } else if let file = selectedFile {
            VStack {
              Spacer()
              Text("No diff available for \(file.filename)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
              Spacer()
            }
            .frame(maxWidth: .infinity)
          } else {
            VStack {
              Spacer()
              Text("Select a file to view its diff")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
              Spacer()
            }
            .frame(maxWidth: .infinity)
          }
        }
      }
    }
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
            .font(.system(size: 13, weight: .medium))
          Text(msg)
            .font(.system(size: 11))
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
              .font(.system(size: 12))
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
                      .font(.system(size: 12, weight: .medium))

                    HStack(spacing: 4) {
                      Text(check.conclusion ?? check.status)
                        .font(.system(size: 10))
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
      if viewModel.checks.isEmpty {
        await viewModel.loadChecks(prNumber: pr.number)
      }
    }
  }

  private func checkColor(_ check: GitHubCheckRun) -> Color {
    switch check.conclusion?.uppercased() {
    case "SUCCESS": return .green
    case "FAILURE", "ERROR", "TIMED_OUT": return .red
    case "NEUTRAL", "SKIPPED": return .secondary
    default: return .orange
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
              .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 12))
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
            .font(.system(size: 11, weight: .semibold))
        }
        if let created = comment.createdAt {
          Text(relativeTime(created))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        Spacer()
      }

      Text(comment.body)
        .font(.system(size: 12))
        .textSelection(.enabled)
    }
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
            .font(.system(size: 11, weight: .semibold))
        }
        if let path = comment.path {
          Text(path)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.blue)
            .lineLimit(1)
        }
        if let line = comment.line {
          Text("L\(line)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let created = comment.createdAt {
          Text(relativeTime(created))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
      }

      if let hunk = comment.diffHunk {
        Text(hunk.components(separatedBy: "\n").suffix(3).joined(separator: "\n"))
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
          .padding(6)
          .background(
            RoundedRectangle(cornerRadius: 4)
              .fill(colorScheme == .dark ? Color(white: 0.04) : Color(white: 0.93))
          )
      }

      Text(comment.body)
        .font(.system(size: 12))
        .textSelection(.enabled)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
    )
  }

  private var commentInput: some View {
    HStack(spacing: 8) {
      TextField("Add a comment...", text: $viewModel.newCommentText, axis: .vertical)
        .font(.system(size: 12))
        .textFieldStyle(.plain)
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
        Task { await viewModel.submitPRComment() }
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
        .font(.system(size: 14, weight: .semibold))

      Picker("Review Type", selection: $selectedEvent) {
        Text("Comment").tag(GitHubReviewInput.Event.comment)
        Text("Approve").tag(GitHubReviewInput.Event.approve)
        Text("Request Changes").tag(GitHubReviewInput.Event.requestChanges)
      }
      .pickerStyle(.segmented)

      TextEditor(text: $viewModel.reviewBody)
        .font(.system(size: 12))
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
