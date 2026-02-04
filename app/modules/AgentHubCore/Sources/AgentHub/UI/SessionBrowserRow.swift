//
//  SessionBrowserRow.swift
//  AgentHub
//
//  Compact row component for displaying sessions in the Hub Sessions browser.
//

import Foundation
import SwiftUI

// MARK: - SessionBrowserRow

/// A compact row for displaying a session in the Hub Sessions browser sidebar.
/// Shows focus/highlight states and allows selection.
struct SessionBrowserRow: View {
  let session: CLISession
  let state: SessionMonitorState?
  let providerKind: SessionProviderKind
  let isFocused: Bool
  let isHighlighted: Bool
  let customName: String?
  let onSelect: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        // Provider icon
        providerIcon

        // Session info
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(displayName)
              .font(.system(.subheadline, weight: .medium))
              .foregroundColor(.primary)
              .lineLimit(1)

            if let branchName = session.branchName {
              Text(branchName)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                  RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                )
                .lineLimit(1)
            }
          }

          HStack(spacing: 4) {
            // Status indicator
            statusIndicator

            // Last activity
            Text(timeAgo)
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }

        Spacer()

        // Focus/highlight indicator
        if isFocused {
          Image(systemName: "chevron.right.circle.fill")
            .font(.system(size: 14))
            .foregroundColor(.brandPrimary(for: providerKind))
        } else if isHighlighted {
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.brandPrimary(for: providerKind).opacity(0.7))
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(backgroundView)
      .overlay(borderOverlay)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
    }
    .buttonStyle(.plain)
  }

  // MARK: - Subviews

  private var providerIcon: some View {
    ZStack {
      Circle()
        .fill(Color.brandPrimary(for: providerKind).opacity(0.15))
        .frame(width: 28, height: 28)

      Image(systemName: providerKind == .claude ? "brain.head.profile" : "cube")
        .font(.system(size: 12))
        .foregroundColor(.brandPrimary(for: providerKind))
    }
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if let state = state {
      switch state.status {
      case .thinking, .executingTool:
        Circle()
          .fill(Color.green)
          .frame(width: 6, height: 6)
      case .waitingForUser:
        Circle()
          .fill(Color.blue)
          .frame(width: 6, height: 6)
      case .awaitingApproval:
        Circle()
          .fill(Color.orange)
          .frame(width: 6, height: 6)
      case .idle:
        Circle()
          .fill(Color.gray)
          .frame(width: 6, height: 6)
      }
    } else {
      Circle()
        .fill(Color.gray.opacity(0.5))
        .frame(width: 6, height: 6)
    }
  }

  @ViewBuilder
  private var backgroundView: some View {
    if isFocused {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.2 : 0.12))
    } else if isHighlighted {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.brandPrimary(for: providerKind).opacity(colorScheme == .dark ? 0.1 : 0.06))
    } else {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.surfaceOverlay)
    }
  }

  @ViewBuilder
  private var borderOverlay: some View {
    if isFocused {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(Color.brandPrimary(for: providerKind).opacity(0.5), lineWidth: 1.5)
    } else if isHighlighted {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(Color.brandPrimary(for: providerKind).opacity(0.3), lineWidth: 1)
    } else {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    }
  }

  // MARK: - Helpers

  private var displayName: String {
    if let customName = customName, !customName.isEmpty {
      return customName
    }
    return session.displayName
  }

  private var timeAgo: String {
    let activityDate = state?.lastActivityAt ?? session.lastActivityAt
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: activityDate, relativeTo: Date())
  }
}
