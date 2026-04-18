//
//  GitHubComponents.swift
//  AgentHub
//
//  Shared reusable components for the GitHub panel UI.
//

import AgentHubGitHub
import SwiftUI

// MARK: - GitHub Design Palette

/// Centralized color palette for all GitHub UI components.
enum GitHubPalette {
  static let addition = Color(hex: "10B981")  // Emerald green
  static let deletion = Color(hex: "EF4444")  // Red
  static let open = Color(hex: "10B981")       // Same emerald for open state
  static let merged = Color(hex: "A855F7")     // Purple
  static let closed = Color(hex: "EF4444")     // Red for closed
  static let linesChanged = Color(hex: "10B981")
}

// MARK: - Author Avatar

struct AuthorAvatarView: View {
  let login: String
  let size: CGFloat

  @Environment(\.runtimeTheme) private var runtimeTheme

  init(login: String, size: CGFloat = 22) {
    self.login = login
    self.size = size
  }

  private var initial: String {
    String(login.prefix(1)).uppercased()
  }

  var body: some View {
    let avatarColor = Color.brandPrimary(from: runtimeTheme)
    ZStack {
      Circle()
        .fill(avatarColor.opacity(0.2))
      Circle()
        .stroke(avatarColor.opacity(0.4), lineWidth: 1)
      Text(initial)
        .font(.geist(size: size * 0.48, weight: .semibold))
        .foregroundStyle(avatarColor)
    }
    .frame(width: size, height: size)
  }
}

// MARK: - Stat Card

struct StatCardView: View {
  let value: String
  let label: String
  let tintColor: Color

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(value)
        .font(.jetBrainsMono(size: 24, weight: .bold))
        .foregroundStyle(.primary)
      Text(label.uppercased())
        .font(GitHubTypography.caption)
        .tracking(0.8)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .padding(.vertical, DesignTokens.Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
        .fill(cardBackground)
    )
    .overlay(
      RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
        .stroke(tintColor.opacity(0.25), lineWidth: 1)
    )
  }

  private var cardBackground: Color {
    if runtimeTheme?.hasCustomBackgrounds == true {
      return Color.adaptiveExpandedContentBackground(for: colorScheme, theme: runtimeTheme)
    }
    return colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.98)
  }
}

// MARK: - Additions / Deletions Badge

struct AdditionsDeletionsBadge: View {
  let additions: Int
  let deletions: Int

  var body: some View {
    HStack(spacing: 3) {
      Text("+\(additions)")
        .font(GitHubTypography.monoCaption)
        .foregroundStyle(GitHubPalette.addition)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(GitHubPalette.addition.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 3))

      Text("-\(deletions)")
        .font(GitHubTypography.monoCaption)
        .foregroundStyle(GitHubPalette.deletion)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(GitHubPalette.deletion.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
  }
}

// MARK: - Branch Badge

struct BranchBadge: View {
  let name: String

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 8))
      Text(name)
        .font(GitHubTypography.monoCaption)
        .lineLimit(1)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Color.blue.opacity(0.1))
    .foregroundStyle(.blue)
    .clipShape(RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous))
  }
}

// MARK: - Label Pill

struct GitHubLabelPill: View {
  let label: GitHubLabel

  private var pillColor: Color {
    guard let hex = label.color else { return .secondary }
    return Color(hex: hex)
  }

  var body: some View {
    Text(label.name)
      .font(GitHubTypography.badge)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(pillColor.opacity(0.15))
      .foregroundStyle(pillColor)
      .clipShape(Capsule())
  }
}

// MARK: - CI Status Badge

struct CIStatusBadge: View {
  let status: CIStatus

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: status.icon)
        .font(.system(size: 9))
      Text(status.rawValue.capitalized)
        .font(GitHubTypography.badge)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(statusColor.opacity(0.15))
    .foregroundStyle(statusColor)
    .clipShape(Capsule())
  }

  private var statusColor: Color {
    switch status {
    case .success: return GitHubPalette.addition
    case .failure: return GitHubPalette.deletion
    case .pending: return .orange
    case .none: return .secondary
    }
  }
}

// MARK: - Review Decision Badge

struct ReviewDecisionBadge: View {
  let decision: String

  private var resolvedDecision: GitHubReviewDecisionState {
    GitHubReviewDecisionState(rawValue: decision)
  }

  private var label: String {
    switch resolvedDecision {
    case .approved: return "Approved"
    case .changesRequested: return "Changes Requested"
    case .reviewRequired: return "Review Required"
    case .unknown(let raw): return raw
    }
  }

  private var color: Color {
    switch resolvedDecision {
    case .approved: return GitHubPalette.addition
    case .changesRequested: return .orange
    case .reviewRequired: return .secondary
    case .unknown: return .secondary
    }
  }

  private var icon: String {
    switch resolvedDecision {
    case .approved: return "checkmark.circle.fill"
    case .changesRequested: return "exclamationmark.circle.fill"
    case .reviewRequired: return "eye.circle"
    case .unknown: return "minus.circle"
    }
  }

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: icon)
        .font(.system(size: 10))
      Text(label)
        .font(GitHubTypography.badge)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(color.opacity(0.15))
    .foregroundStyle(color)
    .clipShape(Capsule())
  }
}

// MARK: - Underline Tab Bar

struct GitHubUnderlineTabBar<Tab: Identifiable & Hashable>: View {
  let tabs: [Tab]
  @Binding var selected: Tab
  let icon: (Tab) -> String
  let title: (Tab) -> String
  var badge: ((Tab) -> Int?)? = nil
  var onSelect: ((Tab) -> Void)? = nil
  var trailing: (() -> AnyView)? = nil

  @Namespace private var tabNamespace
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    let accent = Color.brandPrimary(from: runtimeTheme)
    HStack(spacing: DesignTokens.Spacing.lg) {
      ForEach(tabs) { tab in
        tabSegment(tab, accent: accent)
      }

      Spacer()

      if let trailing {
        trailing()
      }
    }
    .padding(.horizontal, DesignTokens.Spacing.md)
    .frame(height: AgentHubLayout.subBarHeight, alignment: .bottom)
  }

  @ViewBuilder
  private func tabSegment(_ tab: Tab, accent: Color) -> some View {
    let isSelected = selected == tab
    Button {
      withAnimation(.easeInOut(duration: 0.2)) {
        selected = tab
      }
      onSelect?(tab)
    } label: {
      VStack(spacing: DesignTokens.Spacing.xs) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Image(systemName: icon(tab))
            .font(.system(size: 11))
          Text(title(tab))
            .font(GitHubTypography.button)
          if let count = badge?(tab), count > 0 {
            Text("\(count)")
              .font(GitHubTypography.monoCaption)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.secondary.opacity(0.18))
              .clipShape(Capsule())
          }
        }
        .foregroundStyle(isSelected ? accent : .secondary)

        ZStack {
          Rectangle()
            .fill(Color.clear)
            .frame(height: 2)
          if isSelected {
            Rectangle()
              .fill(accent)
              .frame(height: 2)
              .matchedGeometryEffect(id: "underline", in: tabNamespace)
          }
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Gradient Divider

struct GradientDivider: View {
  @Environment(\.runtimeTheme) private var runtimeTheme

  var body: some View {
    let accent = Color.brandPrimary(from: runtimeTheme)
    Rectangle()
      .fill(
        LinearGradient(
          colors: [accent.opacity(0.3), accent.opacity(0.05), Color.clear],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .frame(height: 1)
  }
}

// MARK: - Comment Card

struct GitHubCommentCard: View {
  let author: GitHubAuthor?
  let createdAt: Date?
  let commentBody: String
  var trailingHeader: AnyView? = nil

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        if let author {
          AuthorAvatarView(login: author.login, size: 20)
          Text(author.login)
            .font(GitHubTypography.sectionLabel)
        }
        if let created = createdAt {
          Text(relativeTime(created))
            .font(GitHubTypography.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        if let trailing = trailingHeader {
          trailing
        }
      }

      Text(commentBody)
        .font(GitHubTypography.body)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(DesignTokens.Spacing.md)
    .agentHubCard(transparent: true)
  }
}

// MARK: - Comment Input

struct GitHubCommentInput: View {
  @Binding var text: String
  let isSubmitting: Bool
  let onSubmit: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      TextField("Add a comment...", text: $text, axis: .vertical)
        .font(GitHubTypography.body)
        .textFieldStyle(.plain)
        .submitLabel(.send)
        .onSubmit(onSubmit)
        .lineLimit(1...4)
        .padding(DesignTokens.Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.96))
        )
        .overlay(
          RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius, style: .continuous)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )

      Button(action: onSubmit) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 20))
          .foregroundStyle(text.isEmpty ? Color.secondary : Color.brandPrimary)
      }
      .buttonStyle(.plain)
      .disabled(text.isEmpty || isSubmitting)
    }
    .padding(DesignTokens.Spacing.md)
  }
}

// MARK: - Helper

func abbreviateNumber(_ n: Int) -> String {
  if n >= 1000 {
    let k = Double(n) / 1000.0
    return String(format: "%.1fk", k)
  }
  return "\(n)"
}
