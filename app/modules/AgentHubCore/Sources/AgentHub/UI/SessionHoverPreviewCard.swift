//
//  SessionHoverPreviewCard.swift
//  AgentHub
//
//  Popup shown when hovering a sidebar session row: session name, first user
//  message, parent repo, worktree path, branch, and PR/CI status.
//

import AgentHubGitHub
import SwiftUI

// MARK: - SessionHoverPreviewCard

struct SessionHoverPreviewCard: View {
  let preview: SessionHoverPreview
  let timestamp: Date
  let gitHubViewModel: SessionGitHubQuickAccessViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(preview.sessionName)
          .font(.primaryDefault.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Spacer(minLength: 12)

        Text(timestamp.timeAgoDisplay())
          .font(.secondaryCaption)
          .foregroundStyle(.secondary)
          .fixedSize()
      }

      if let firstMessage = preview.firstMessage {
        Text(firstMessage)
          .font(.secondaryDefault)
          .foregroundStyle(.primary.opacity(0.85))
          .lineLimit(4)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        SessionHoverPreviewDetailRow(icon: "folder", text: preview.repositoryName)

        if let worktreePath = preview.displayWorktreePath() {
          SessionHoverPreviewDetailRow(icon: "arrow.triangle.pull", text: worktreePath)
        }

        if let branch = preview.branchName {
          SessionHoverPreviewDetailRow(icon: "arrow.triangle.branch", text: branch)
        }

        if let pullRequest = gitHubViewModel.currentBranchPR {
          GitHubSessionRowStatusLine(
            pullRequest: pullRequest,
            summary: gitHubViewModel.ciSummary,
            observationState: gitHubViewModel.observationState,
            lastRefreshedAt: gitHubViewModel.lastRefreshedAt
          )
        }
      }
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
  }
}

// MARK: - SessionHoverPreviewDetailRow

struct SessionHoverPreviewDetailRow: View {
  let icon: String
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 12, height: 12)

      Text(text)
        .font(.secondarySmall)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

// MARK: - Preview

#Preview("SessionHoverPreviewCard") {
  SessionHoverPreviewCard(
    preview: SessionHoverPreview(
      sessionName: "cryptic-orbiting-flame",
      firstMessage: "lets modify the aspect ratio of the shader canvas so it fills the window",
      repositoryName: "ShaderKit",
      branchName: "main",
      worktreePath: "~/Developer/ShaderKit-shader-canvas"
    ),
    timestamp: Date().addingTimeInterval(-90 * 24 * 3600),
    gitHubViewModel: SessionGitHubQuickAccessViewModel()
  )
  .padding()
}
