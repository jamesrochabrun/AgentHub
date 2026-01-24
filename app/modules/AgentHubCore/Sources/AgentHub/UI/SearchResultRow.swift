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
      HStack(alignment: .top, spacing: 12) {
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
              .lineLimit(1)
          }
          .foregroundColor(.secondary)

          // Matched text with field indicator
          matchedTextView

          // Branch if available
          if let branch = result.gitBranch {
            HStack(spacing: 4) {
              Image(systemName: "arrow.triangle.branch")
                .font(.caption)
              Text(branch)
                .font(.caption)
                .lineLimit(1)
            }
            .foregroundColor(.secondary.opacity(0.8))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // Date
        VStack(alignment: .trailing, spacing: 4) {
          Text(preciseDateString(from: result.lastActivityAt))
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

      Text(result.matchedText)
        .font(.caption)
        .foregroundColor(.primary.opacity(0.8))
        .lineLimit(1)
    }
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

  private func preciseDateString(from date: Date) -> String {
    let formatter = DateFormatter()
    let calendar = Calendar.current

    if calendar.isDateInToday(date) {
      // Show time for today: "3:42 PM"
      formatter.dateFormat = "h:mm a"
    } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
      // Same year: "Jan 17"
      formatter.dateFormat = "MMM d"
    } else {
      // Different year: "Jan 17, 2025"
      formatter.dateFormat = "MMM d, yyyy"
    }

    return formatter.string(from: date)
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 12) {
    // Today - shows time (e.g., "3:42 PM")
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

    // Same year - shows "Jan 17"
    SearchResultRow(
      result: SessionSearchResult(
        id: "def456",
        slug: "async-coalescing-summit",
        projectPath: "/Users/user/Projects/AgentHub",
        gitBranch: "jroch-inline-request",
        firstMessage: "Implement the following plan:",
        summaries: ["Fixed authentication bug", "Updated login flow"],
        lastActivityAt: Calendar.current.date(byAdding: .day, value: -2, to: Date())!,
        matchedField: .summary,
        matchedText: "Fixed authentication bug"
      ),
      onSelect: {}
    )

    // Same slug, different date - shows "Jan 15"
    SearchResultRow(
      result: SessionSearchResult(
        id: "ghi789",
        slug: "async-coalescing-summit",
        projectPath: "/Users/user/Projects/AgentHub",
        gitBranch: "jroch-inline-request",
        firstMessage: "Implement the following plan:",
        summaries: ["Added new feature"],
        lastActivityAt: Calendar.current.date(byAdding: .day, value: -4, to: Date())!,
        matchedField: .firstMessage,
        matchedText: "Implement the following plan:"
      ),
      onSelect: {}
    )

    // Different year - shows "Jan 17, 2025"
    SearchResultRow(
      result: SessionSearchResult(
        id: "jkl012",
        slug: "happy-dancing-penguin",
        projectPath: "/Users/user/Projects/OtherApp",
        gitBranch: "main",
        firstMessage: nil,
        summaries: ["Old session"],
        lastActivityAt: Calendar.current.date(from: DateComponents(year: 2025, month: 1, day: 17))!,
        matchedField: .summary,
        matchedText: "Old session"
      ),
      onSelect: {}
    )
  }
  .padding()
  .frame(width: 400)
}
