//
//  GitHubIssueDetailView.swift
//  AgentHub
//
//  Detailed view for a GitHub issue with comments and actions
//

import AgentHubGitHub
import SwiftUI

// MARK: - GitHubIssueDetailView

struct GitHubIssueDetailView: View {
  @Bindable var viewModel: GitHubViewModel
  let issue: GitHubIssue
  let session: CLISession?
  let onSendToSession: ((String, CLISession) -> Void)?
  let onStartNewSession: ((String, SessionProviderKind) -> Void)?

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      navigationHeader
      GradientDivider()
      issueInfoHeader
      GradientDivider()
      issueBody
      GradientDivider()
      GitHubCommentInput(
        text: $viewModel.newCommentText,
        isSubmitting: viewModel.isSubmittingComment
      ) {
        Task { await viewModel.submitIssueComment() }
      }
    }
  }

  // MARK: - Navigation Header

  private var navigationHeader: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Button {
        viewModel.deselectIssue()
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

      if let session, let onSendToSession {
        Button {
          var prompt = "Look at issue #\(issue.number): \(issue.title)."
          if let body = issue.body {
            let truncated = body.prefix(200)
            prompt += "\n\nDescription: \(truncated)\(body.count > 200 ? "..." : "")"
          }
          onSendToSession(prompt, session)
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "arrow.right.circle")
              .font(.system(size: 10))
            Text("Send to Session")
          }
        }
        .buttonStyle(.agentHubOutlined(tint: Color.brandPrimary))
      } else if let onStartNewSession {
        Menu {
          Button {
            onStartNewSession("fix \(issue.url)", .claude)
          } label: {
            Label("Claude", systemImage: "c.circle")
          }
          Button {
            onStartNewSession("fix \(issue.url)", .codex)
          } label: {
            Label("Codex", systemImage: "c.square")
          }
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "wrench")
              .font(.system(size: 10))
            Text("Fix")
          }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.agentHubOutlined(tint: Color.brandPrimary))
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.sm)
  }

  // MARK: - Issue Info Header

  private var issueInfoHeader: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      // State + number row
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: issue.stateIcon)
          .font(.system(size: 14))
          .foregroundStyle(issueStateColor)

        Text("#\(issue.number)")
          .font(GitHubTypography.monoTitle)
          .foregroundStyle(Color.brandPrimary)

        Text(issue.stateKind.displayName)
          .font(GitHubTypography.badge)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(issueStateColor.opacity(0.15))
          .foregroundStyle(issueStateColor)
          .clipShape(Capsule())
      }

      Text(issue.title)
        .font(GitHubTypography.sectionTitle)
        .fixedSize(horizontal: false, vertical: true)

      // Metadata row
      HStack(spacing: DesignTokens.Spacing.md) {
        if let author = issue.author {
          HStack(spacing: DesignTokens.Spacing.xs) {
            AuthorAvatarView(login: author.login, size: 18)
            Text(author.login)
              .font(GitHubTypography.bodySmall)
          }
          .foregroundStyle(.secondary)
        }

        if let created = issue.createdAt {
          Text(relativeTime(created))
            .font(GitHubTypography.bodySmall)
            .foregroundStyle(.tertiary)
        }

        if let assignees = issue.assignees, !assignees.isEmpty {
          HStack(spacing: -4) {
            ForEach(assignees.prefix(5), id: \.login) { assignee in
              AuthorAvatarView(login: assignee.login, size: 18)
                .overlay(
                  Circle()
                    .stroke(colorScheme == .dark ? Color(white: 0.05) : Color.white, lineWidth: 1.5)
                )
            }
          }
          .help(assignees.map(\.login).joined(separator: ", "))
        }
      }

      if let labels = issue.labels, !labels.isEmpty {
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

  private var issueStateColor: Color {
    switch issue.stateKind {
    case .open: return .green
    case .closed: return .purple
    case .unknown: return .secondary
    }
  }

  // MARK: - Issue Body + Comments

  private var issueBody: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
        // Issue description
        if let body = issue.body, !body.isEmpty {
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
              Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(Color.brandPrimary)
              Text("Description")
                .font(GitHubTypography.sectionLabel)
                .foregroundStyle(.secondary)
            }

            MarkdownCardView(content: body, transparent: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Comments
        if let comments = issue.comments, !comments.isEmpty {
          VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
              Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 11))
                .foregroundStyle(Color.brandPrimary)
              Text("Comments (\(comments.count))")
                .font(GitHubTypography.sectionLabel)
                .foregroundStyle(.secondary)
            }

            ForEach(comments) { comment in
              GitHubCommentCard(
                author: comment.author,
                createdAt: comment.createdAt,
                commentBody: comment.body
              )
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(DesignTokens.Spacing.md)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
