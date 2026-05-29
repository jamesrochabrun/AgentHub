//
//  WorktreeGenerationProgressBar.swift
//  AgentHub
//

import AgentHubCLIKit
import SwiftUI

// MARK: - WorktreeGenerationProgressBar

/// Compact, self-contained card that surfaces live worktree-creation progress
/// (side panel, MCP, and Start Session) above the detail pane. Collapsed: a
/// context-aware summary with a progress hairline. Expanded: per-worktree rows.
/// Renders nothing (zero height) when no creations are tracked.
public struct WorktreeGenerationProgressBar: View {
  @Environment(WorktreeGenerationProgressCoordinator.self) private var coordinator: WorktreeGenerationProgressCoordinator?
  @Environment(\.colorScheme) private var colorScheme
  @State private var isExpanded = false

  public init() {}

  public var body: some View {
    Group {
      if let coordinator, coordinator.isActive {
        card(coordinator)
          .padding(.horizontal, 8)
          .padding(.top, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: coordinator?.isActive ?? false)
    .animation(.easeInOut(duration: 0.2), value: coordinator?.operations.count ?? 0)
    .animation(.easeInOut(duration: 0.18), value: isExpanded)
  }

  // MARK: - Card

  private func card(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    VStack(spacing: 0) {
      header(coordinator)
      if isExpanded {
        Divider().opacity(0.5)
        detailList(coordinator)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
        .fill(cardColor)
    )
    .overlay(alignment: .bottom) {
      progressHairline(coordinator)
    }
    .clipShape(RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: AgentHubLayout.cardCornerRadius, style: .continuous)
        .stroke(accent(coordinator).opacity(0.22), lineWidth: 1)
    )
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.08), radius: 7, y: 2)
  }

  private var cardColor: Color {
    colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.99)
  }

  // MARK: - Header (collapsed summary)

  private func header(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    let model = summary(coordinator)
    return HStack(spacing: 10) {
      leadingIcon(coordinator)
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: 1) {
        Text(model.title)
          .font(.system(.subheadline, weight: .semibold))
          .lineLimit(1)
        if let subtitle = model.subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .monospacedDigit()
        }
      }

      Spacer(minLength: 8)

      if coordinator.inFlightCount > 0 {
        Text("\(Int(coordinator.aggregateProgress * 100))%")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture { isExpanded.toggle() }
    .help(isExpanded ? "Hide details" : "Show details")
  }

  @ViewBuilder
  private func leadingIcon(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    if coordinator.inFlightCount > 0 {
      ProgressView()
        .controlSize(.small)
        .scaleEffect(0.85)
    } else if coordinator.hasFailures {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 14))
        .foregroundStyle(.orange)
    } else {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 15))
        .foregroundStyle(.green)
        .symbolEffect(.bounce, value: coordinator.operations.isEmpty)
    }
  }

  // MARK: - Progress hairline (bottom edge)

  private func progressHairline(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Rectangle().fill(Color.secondary.opacity(0.12))
        Rectangle()
          .fill(accent(coordinator))
          .frame(width: geo.size.width * min(max(coordinator.aggregateProgress, 0), 1))
          .animation(.linear(duration: 0.2), value: coordinator.aggregateProgress)
      }
    }
    .frame(height: 3)
    .opacity(coordinator.inFlightCount > 0 ? 1 : 0.6)
  }

  // MARK: - Expanded detail

  private func detailList(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    ScrollView {
      VStack(spacing: 6) {
        ForEach(coordinator.operations) { op in
          WorktreeGenerationOperationRow(operation: op) {
            coordinator.dismiss(id: op.id)
          }
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .padding(10)
    }
    .frame(maxHeight: 240)
  }

  // MARK: - Summary model

  private func accent(_ coordinator: WorktreeGenerationProgressCoordinator) -> Color {
    if coordinator.hasFailures && coordinator.inFlightCount == 0 { return .orange }
    if coordinator.inFlightCount == 0 { return .green }
    return .brandPrimary
  }

  private func summary(_ coordinator: WorktreeGenerationProgressCoordinator) -> (title: String, subtitle: String?) {
    if coordinator.operations.count == 1, let op = coordinator.operations.first {
      return singleSummary(op)
    }
    if coordinator.inFlightCount > 0 {
      return ("Creating \(coordinator.inFlightCount) worktrees…", "\(coordinator.operations.count) total")
    }
    if coordinator.hasFailures {
      return ("Worktree creation failed", nil)
    }
    return ("\(coordinator.operations.count) worktrees ready", nil)
  }

  private func singleSummary(_ op: WorktreeGenerationOperation) -> (title: String, subtitle: String?) {
    if op.isNaming {
      return ("Generating branch name", op.repoName.isEmpty ? op.progress.statusMessage : op.repoName)
    }
    switch op.progress {
    case .completed:
      return (op.branchName.isEmpty ? "Worktree ready" : op.branchName, "Ready")
    case .failed(let error):
      return (op.branchName.isEmpty ? "Creation failed" : op.branchName, error)
    case .cancelled:
      return (op.branchName.isEmpty ? "Cancelled" : op.branchName, "Cancelled")
    case .idle, .preparing, .updatingFiles:
      let title = op.branchName.isEmpty ? "Creating worktree" : op.branchName
      let subtitle = op.progress.statusMessage.isEmpty ? op.repoName : op.progress.statusMessage
      return (title, subtitle)
    }
  }
}

// MARK: - WorktreeGenerationOperationRow

private struct WorktreeGenerationOperationRow: View {
  let operation: WorktreeGenerationOperation
  let onDismiss: () -> Void

  private var isNaming: Bool { operation.isNaming }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: rowIcon)
        .font(.system(.body))
        .foregroundStyle(statusColor)
        .frame(width: 20)
        .symbolEffect(.pulse, isActive: isNaming && operation.progress.isInProgress)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(titleText)
            .font(.system(.subheadline, weight: .medium))
            .lineLimit(1)
          if !isNaming {
            providerTag
          }
          Spacer(minLength: 4)
          if !detailTrailing.isEmpty {
            Text(detailTrailing)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }

        if isNaming && operation.progress.isInProgress {
          ProgressView()
            .progressViewStyle(.linear)
            .tint(statusColor)
        } else {
          ProgressView(value: operation.progress.progressValue)
            .tint(statusColor)
            .animation(.linear(duration: 0.15), value: operation.progress.progressValue)
        }

        Text(statusLine)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      if operation.isFailure {
        Button(action: onDismiss) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
      }
    }
    .padding(10)
    .agentHubRow()
  }

  private var rowIcon: String {
    if isNaming {
      if case .completed = operation.progress { return "checkmark.circle.fill" }
      return "sparkles"
    }
    return operation.progress.icon
  }

  private var titleText: String {
    if isNaming {
      if case .completed = operation.progress { return "Branch name ready" }
      return "Generating branch name"
    }
    return operation.branchName
  }

  private var providerTag: some View {
    Text(operation.provider.rawValue)
      .font(.caption2.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(
        RoundedRectangle(cornerRadius: AgentHubLayout.chipCornerRadius)
          .fill(Color.secondary.opacity(0.12))
      )
  }

  private var statusColor: Color {
    switch operation.progress {
    case .completed: return .green
    case .failed: return .red
    case .cancelled: return .secondary
    case .idle, .preparing, .updatingFiles: return .brandPrimary
    }
  }

  private var statusLine: String {
    let message = operation.progress.statusMessage
    if message.isEmpty {
      return operation.repoName
    }
    return "\(operation.repoName) · \(message)"
  }

  private var detailTrailing: String {
    if isNaming { return "" }
    if operation.progress.isInProgress {
      return "\(Int(operation.progress.progressValue * 100))%"
    }
    switch operation.progress {
    case .completed: return "Ready"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    default: return ""
    }
  }
}
