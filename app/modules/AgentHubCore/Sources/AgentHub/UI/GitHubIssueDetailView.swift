//
//  GitHubIssueDetailView.swift
//  AgentHub
//
//  Detailed view for a GitHub issue with comments and actions
//

import SwiftUI

// MARK: - GitHubIssueDetailView

struct GitHubIssueDetailView: View {
  @Bindable var viewModel: GitHubViewModel
  let issue: GitHubIssue
  let session: CLISession?
  let onSendToSession: ((String, CLISession) -> Void)?

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: 0) {
      // Navigation header
      navigationHeader

      Divider()

      // Issue info
      issueInfoHeader

      Divider()

      // Content: body + comments
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          // Issue body
          if let body = issue.body, !body.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Description")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

              Text(body)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  RoundedRectangle(cornerRadius: 8)
                    .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
                )
            }
          }

          // Comments
          if let comments = issue.comments, !comments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Text("Comments (\(comments.count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

              ForEach(comments) { comment in
                issueCommentCard(comment)
              }
            }
          }
        }
        .padding(12)
      }

      Divider()

      // New comment input
      commentInput
    }
  }

  // MARK: - Navigation Header

  private var navigationHeader: some View {
    HStack(spacing: 8) {
      Button {
        viewModel.deselectIssue()
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
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  // MARK: - Issue Info Header

  private var issueInfoHeader: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: issue.stateIcon)
          .font(.system(size: 14))
          .foregroundStyle(issueStateColor)

        Text("#\(issue.number)")
          .font(.system(size: 13, weight: .bold, design: .monospaced))

        Text(issue.stateKind.displayName)
          .font(.system(size: 10, weight: .medium))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            issueStateColor
              .opacity(0.15)
          )
          .foregroundStyle(issueStateColor)
          .clipShape(Capsule())
      }

      Text(issue.title)
        .font(.system(size: 14, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        if let author = issue.author {
          HStack(spacing: 3) {
            Image(systemName: "person")
              .font(.system(size: 9))
            Text(author.login)
              .font(.system(size: 11))
          }
          .foregroundStyle(.secondary)
        }

        if let created = issue.createdAt {
          Text(relativeTime(created))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }

        if let assignees = issue.assignees, !assignees.isEmpty {
          HStack(spacing: 3) {
            Image(systemName: "person.2")
              .font(.system(size: 9))
            Text(assignees.map(\.login).joined(separator: ", "))
              .font(.system(size: 11))
          }
          .foregroundStyle(.secondary)
        }
      }

      if let labels = issue.labels, !labels.isEmpty {
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

  private var issueStateColor: Color {
    switch issue.stateKind {
    case .open: return .green
    case .closed: return .purple
    case .unknown: return .secondary
    }
  }

  // MARK: - Comment Card

  private func issueCommentCard(_ comment: GitHubComment) -> some View {
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

  // MARK: - Comment Input

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
        Task { await viewModel.submitIssueComment() }
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 20))
          .foregroundStyle(viewModel.newCommentText.isEmpty ? Color.secondary : Color.accentColor)
      }
      .buttonStyle(.plain)
      .disabled(viewModel.newCommentText.isEmpty || viewModel.isSubmittingComment)
    }
    .padding(10)
  }
}
