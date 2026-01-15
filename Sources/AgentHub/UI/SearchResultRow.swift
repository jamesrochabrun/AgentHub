//
//  SearchResultRow.swift
//  AgentHub
//
//  Created by Assistant on 1/14/26.
//

import SwiftUI

// MARK: - SearchResultRow

/// A row displaying a search result with session metadata
public struct SearchResultRow: View {
  let result: SessionSearchResult
  let onSelect: () -> Void

  public init(result: SessionSearchResult, onSelect: @escaping () -> Void) {
    self.result = result
    self.onSelect = onSelect
  }

  public var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // Repository icon with add indicator
        ZStack(alignment: .bottomTrailing) {
          Image(systemName: "folder.fill")
            .font(.system(size: 20))
            .foregroundColor(.brandPrimary)

          Image(systemName: "plus.circle.fill")
            .font(.system(size: 10))
            .foregroundColor(.green)
            .background(Circle().fill(Color.surfaceOverlay).padding(-1))
            .offset(x: 4, y: 4)
        }

        VStack(alignment: .leading, spacing: 4) {
          // Slug (session name)
          Text(result.slug)
            .font(.system(.subheadline, design: .monospaced, weight: .semibold))
            .foregroundColor(.brandPrimary)
            .lineLimit(1)

          // Repository name
          HStack(spacing: 4) {
            Image(systemName: "folder")
              .font(.system(size: 10))
            Text(result.repositoryName)
              .font(.caption)
          }
          .foregroundColor(.secondary)

          // Matched text with field indicator
          matchedTextView

          // Branch if available
          if let branch = result.gitBranch {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
              Text(branch)
                .font(.caption)
            }
            .foregroundColor(.secondary.opacity(0.8))
          }
        }

        Spacer()

        // Time ago
        VStack(alignment: .trailing, spacing: 4) {
          Text(timeAgoString(from: result.lastActivityAt))
            .font(.caption)
            .foregroundColor(.secondary)

          // Add indicator
          Text("Add")
            .font(.system(.caption2, weight: .medium))
            .foregroundColor(.brandPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              Capsule()
                .fill(Color.brandPrimary.opacity(0.1))
            )
        }
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .fill(Color.surfaceOverlay)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Matched Text View

  private var matchedTextView: some View {
    HStack(spacing: 4) {
      Image(systemName: result.matchedField.iconName)
        .font(.system(size: 10))
        .foregroundColor(.brandSecondary)

      Text(truncatedMatchText)
        .font(.caption)
        .foregroundColor(.primary.opacity(0.8))
        .lineLimit(1)
    }
  }

  private var truncatedMatchText: String {
    let text = result.matchedText
    if text.count > 60 {
      return String(text.prefix(60)) + "..."
    }
    return text
  }

  // MARK: - Time Formatting

  private func timeAgoString(from date: Date) -> String {
    let now = Date()
    let interval = now.timeIntervalSince(date)

    if interval < 60 {
      return "Just now"
    } else if interval < 3600 {
      let minutes = Int(interval / 60)
      return "\(minutes)m ago"
    } else if interval < 86400 {
      let hours = Int(interval / 3600)
      return "\(hours)h ago"
    } else if interval < 604800 {
      let days = Int(interval / 86400)
      return "\(days)d ago"
    } else {
      let formatter = DateFormatter()
      formatter.dateFormat = "MMM d"
      return formatter.string(from: date)
    }
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 12) {
    SearchResultRow(
      result: SessionSearchResult(
        id: "abc123",
        slug: "cryptic-orbiting-flame",
        projectPath: "/Users/user/Projects/MyApp",
        gitBranch: "feature/search",
        firstMessage: "Help me implement search",
        summaries: ["Added search functionality"],
        lastActivityAt: Date().addingTimeInterval(-3600),
        matchedField: .slug,
        matchedText: "cryptic-orbiting-flame"
      ),
      onSelect: {}
    )

    SearchResultRow(
      result: SessionSearchResult(
        id: "def456",
        slug: "happy-dancing-penguin",
        projectPath: "/Users/user/Projects/OtherApp",
        gitBranch: "main",
        firstMessage: nil,
        summaries: ["Fixed authentication bug", "Updated login flow"],
        lastActivityAt: Date().addingTimeInterval(-86400),
        matchedField: .summary,
        matchedText: "Fixed authentication bug"
      ),
      onSelect: {}
    )
  }
  .padding()
  .frame(width: 400)
}
