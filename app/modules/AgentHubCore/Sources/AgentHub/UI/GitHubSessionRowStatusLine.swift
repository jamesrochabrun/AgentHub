//
//  GitHubSessionRowStatusLine.swift
//  AgentHub
//
//  Compact PR + CI status line shared by session rows and the hover preview.
//

import AgentHubGitHub
import SwiftUI

// MARK: - GitHubSessionRowStatusLine

struct GitHubSessionRowStatusLine: View {
  let pullRequest: GitHubPullRequest
  let summary: GitHubCISummary
  let observationState: GitHubPRObservationState
  let lastRefreshedAt: Date?

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: primaryIcon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(primaryColor)
        .frame(width: 12, height: 12)

      Text(primaryText)
        .font(.geist(size: 10, weight: .medium))
        .foregroundColor(.secondary.opacity(0.95))

      if let secondaryText {
        Text("·")
          .font(.secondaryCaption)
          .foregroundColor(.secondary.opacity(0.55))

        Image(systemName: secondaryIcon)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(secondaryColor)
          .frame(width: 11, height: 11)

        Text(secondaryText)
          .font(.secondaryCaption)
          .foregroundColor(.secondary.opacity(0.86))
      }
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(helpText)
    .accessibilityLabel(helpText)
  }

  private var primaryText: String {
    switch pullRequest.stateKind {
    case .open:
      return pullRequest.isDraft ? "Draft PR #\(pullRequest.number)" : "Open PR #\(pullRequest.number)"
    case .closed:
      return "Closed PR #\(pullRequest.number)"
    case .merged:
      return "Merged PR #\(pullRequest.number)"
    case .unknown:
      return "PR #\(pullRequest.number)"
    }
  }

  private var secondaryText: String? {
    if observationState.isRefreshing && summary.total == 0 {
      return "Refreshing checks"
    }

    if observationState.isUnavailable {
      return lastRefreshedAt == nil
        ? "GitHub unavailable"
        : "Last known: \(statusText)"
    }

    return statusText
  }

  private var statusText: String {
    let blockers = GitHubPRBlocker.blockers(
      for: pullRequest,
      ciSummary: summary
    ).sorted { $0.rawValue < $1.rawValue }
    if blockers.count == 1, let blocker = blockers.first {
      return blocker.displayName
    }
    if blockers.count > 1 {
      return "\(blockers.count) PR blockers"
    }

    guard summary.total > 0 else {
      return "No CI checks"
    }

    switch summary.overallStatus {
    case .success:
      return "CI passing \(summary.passed)/\(summary.total)"
    case .failure:
      return "CI failing \(summary.failed) failed"
    case .pending:
      return "CI running \(summary.pending) pending"
    case .none:
      if summary.skipped > 0 {
        return "CI skipped \(summary.skipped)"
      }
      return "No CI checks"
    }
  }

  private var primaryIcon: String {
    return pullRequest.stateIcon
  }

  private var secondaryIcon: String {
    if observationState.isRefreshing && summary.total == 0 {
      return "arrow.clockwise"
    }
    if observationState.isUnavailable || !blockers.isEmpty {
      return "exclamationmark.triangle.fill"
    }
    return summary.overallStatus.icon
  }

  private var primaryColor: Color {
    switch pullRequest.stateKind {
    case .open:
      return pullRequest.isDraft ? .secondary : .green
    case .closed:
      return .red
    case .merged:
      return .purple
    case .unknown:
      return .secondary
    }
  }

  private var secondaryColor: Color {
    if observationState.isRefreshing && summary.total == 0 {
      return .orange
    }
    if !blockers.isEmpty { return .red }
    if observationState.isUnavailable { return .orange }
    switch summary.overallStatus {
    case .success:
      return .green
    case .failure:
      return .red
    case .pending:
      return .orange
    case .none:
      return .secondary
    }
  }

  private var helpText: String {
    let prText: String
    switch pullRequest.stateKind {
    case .open:
      prText = pullRequest.isDraft
        ? "Draft PR #\(pullRequest.number)"
        : "Open PR #\(pullRequest.number)"
    case .closed:
      prText = "Closed PR #\(pullRequest.number)"
    case .merged:
      prText = "Merged PR #\(pullRequest.number)"
    case .unknown:
      prText = "PR #\(pullRequest.number) has an unknown state"
    }

    return "\(prText). \(ciHelpText)"
  }

  private var ciHelpText: String {
    if observationState.isRefreshing && summary.total == 0 {
      return "CI checks are refreshing."
    }

    if observationState.isUnavailable {
      let availability = lastRefreshedAt == nil
        ? "GitHub status is unavailable."
        : "GitHub status is unavailable; showing the last known result."
      return "\(availability) \(currentGitHubHelpText)"
    }

    return currentGitHubHelpText
  }

  private var currentGitHubHelpText: String {
    if !blockers.isEmpty {
      let descriptions = blockers
        .sorted { $0.rawValue < $1.rawValue }
        .map(\.displayName)
        .joined(separator: ", ")
      return "Pull request blockers: \(descriptions)."
    }

    guard summary.total > 0 else {
      return "No CI checks are reported."
    }

    switch summary.overallStatus {
    case .success:
      return "CI passing: \(summary.passed) of \(summary.total) checks passed."
    case .failure:
      return "CI failing: \(summary.failed) failed, \(summary.passed) passed, \(summary.pending) pending."
    case .pending:
      return "CI running: \(summary.pending) pending, \(summary.passed) passed, \(summary.failed) failed."
    case .none:
      if summary.skipped > 0 {
        return "CI checks are skipped or neutral: \(summary.skipped) of \(summary.total)."
      }
      return "No CI checks are reported."
    }
  }

  private var blockers: Set<GitHubPRBlocker> {
    GitHubPRBlocker.blockers(for: pullRequest, ciSummary: summary)
  }
}
