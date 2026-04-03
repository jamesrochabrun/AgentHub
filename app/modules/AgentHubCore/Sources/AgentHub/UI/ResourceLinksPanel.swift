//
//  ResourceLinksPanel.swift
//  AgentHub
//
//  Created by Assistant on 3/11/26.
//

import AgentHubGitHub
import SwiftUI

// MARK: - ResourceLinksPanel

/// A compact bottom panel that displays clickable resource links detected in session responses
struct ResourceLinksPanel: View {
  let links: [ResourceLink]
  let providerKind: SessionProviderKind
  var currentPullRequest: GitHubPullRequest? = nil
  var onOpenCurrentPullRequest: ((GitHubPullRequest) -> Void)? = nil

  @State private var isExpanded = false

  private var hasLinks: Bool {
    !links.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider()

      HStack(spacing: 8) {
        if hasLinks {
          Button(action: toggleExpanded) {
            HStack(spacing: 6) {
              headerLabel
              Text("\(links.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())

              Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        } else {
          headerLabel
        }

        Spacer(minLength: 0)

        if let currentPullRequest {
          CurrentPullRequestChip(
            pullRequest: currentPullRequest,
            action: { openCurrentPullRequest(currentPullRequest) }
          )
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)

      if hasLinks && isExpanded {
        Divider()

        // Scrollable link list
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(links) { link in
              ResourceLinkChip(link: link, providerKind: providerKind)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
        }
      }
    }
    .background(Color.primary.opacity(0.03))
  }

  private var headerLabel: some View {
    HStack(spacing: 6) {
      Image(systemName: "link")
        .font(.caption2)
        .foregroundStyle(Color.brandPrimary(for: providerKind))

      Text("Resources")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.primary)
    }
  }

  private func toggleExpanded() {
    withAnimation(.easeInOut(duration: 0.2)) {
      isExpanded.toggle()
    }
  }

  private func openCurrentPullRequest(_ pullRequest: GitHubPullRequest) {
    if let onOpenCurrentPullRequest {
      onOpenCurrentPullRequest(pullRequest)
      return
    }

    guard let url = URL(string: pullRequest.url) else { return }
    NSWorkspace.shared.open(url)
  }
}

// MARK: - ResourceLinkChip

/// A compact clickable chip for a single resource link
private struct ResourceLinkChip: View {
  let link: ResourceLink
  let providerKind: SessionProviderKind
  @State private var isHovering = false

  var body: some View {
    Button(action: openLink) {
      HStack(spacing: 4) {
        Image(systemName: iconForURL(link.url))
          .font(.caption2)

        VStack(alignment: .leading, spacing: 0) {
          Text(link.displayTitle)
            .font(.caption2)
            .fontWeight(.medium)
            .lineLimit(1)
          Text(link.displayDomain)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(
        isHovering
          ? Color.brandPrimary(for: providerKind).opacity(0.12)
          : Color.secondary.opacity(0.08)
      )
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering in isHovering = hovering }
    .help(link.url)
  }

  private func openLink() {
    guard let url = URL(string: link.url) else { return }
    NSWorkspace.shared.open(url)
  }

  private func iconForURL(_ urlString: String) -> String {
    let lowered = urlString.lowercased()
    if lowered.contains("github.com") {
      return "curlybraces"
    } else if lowered.contains("docs.") || lowered.contains("documentation") {
      return "doc.text"
    } else if lowered.contains("stackoverflow.com") {
      return "questionmark.circle"
    } else if lowered.contains("npm") || lowered.contains("pypi") || lowered.contains("crates.io") {
      return "shippingbox"
    } else {
      return "globe"
    }
  }
}

// MARK: - CurrentPullRequestChip

private struct CurrentPullRequestChip: View {
  let pullRequest: GitHubPullRequest
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Text("PR #\(pullRequest.number)")
          .font(.caption)
          .bold()
          .underline()
          .foregroundStyle(.primary)
          .lineLimit(1)

        Text("\(formattedCount(pullRequest.changedFiles)) files")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        Text("+\(formattedCount(pullRequest.additions))")
          .font(.caption)
          .bold()
          .foregroundStyle(.green)
          .lineLimit(1)

        Text("-\(formattedCount(pullRequest.deletions))")
          .font(.caption)
          .bold()
          .foregroundStyle(.red)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("\(pullRequest.title)\n\(pullRequest.url)")
    .accessibilityLabel(
      "Open pull request \(pullRequest.number) on GitHub. \(pullRequest.changedFiles) files changed, plus \(pullRequest.additions), minus \(pullRequest.deletions)."
    )
  }

  private func formattedCount(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
  }
}

// MARK: - Preview

#Preview {
  VStack {
    ResourceLinksPanel(
      links: [
        ResourceLink(url: "https://github.com/anthropics/claude-code/issues/123"),
        ResourceLink(url: "https://docs.swift.org/swift-book/documentation/the-swift-programming-language"),
        ResourceLink(url: "https://stackoverflow.com/questions/12345/some-question"),
        ResourceLink(url: "https://example.com/api/v2/endpoint"),
      ],
      providerKind: .claude,
      currentPullRequest: GitHubPullRequest(
        number: 187,
        title: "Add GitHub integration with PR/issue management UI",
        body: nil,
        state: "OPEN",
        url: "https://github.com/jamesrochabrun/AgentHub/pull/187",
        headRefName: "feature/github",
        baseRefName: "main",
        author: nil,
        createdAt: nil,
        updatedAt: nil,
        isDraft: false,
        mergeable: "MERGEABLE",
        additions: 4195,
        deletions: 0,
        changedFiles: 12,
        reviewDecision: nil,
        statusCheckRollup: nil,
        labels: nil,
        reviewRequests: nil,
        comments: nil
      )
    )
  }
  .frame(width: 400)
}
