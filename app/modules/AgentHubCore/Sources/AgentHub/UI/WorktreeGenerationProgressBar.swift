//
//  WorktreeGenerationProgressBar.swift
//  AgentHub
//

import AgentHubCLIKit
import SwiftUI

// MARK: - WorktreeGenerationProgressBar

/// Compact top bar that surfaces live worktree-creation progress from both the
/// side panel and MCP. Collapsed: an aggregate progress bar + count. Expanded:
/// a per-worktree detail list. Renders nothing when no creations are tracked.
public struct WorktreeGenerationProgressBar: View {
  @Environment(WorktreeGenerationProgressCoordinator.self) private var coordinator: WorktreeGenerationProgressCoordinator?
  @State private var isExpanded = false

  public init() {}

  public var body: some View {
    Group {
      if let coordinator, coordinator.isActive {
        content(coordinator)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    // Appear/dismiss is driven by isActive; row add/remove and expand toggle
    // get their own shorter animations.
    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: coordinator?.isActive ?? false)
    .animation(.easeInOut(duration: 0.2), value: coordinator?.operations.count ?? 0)
    .animation(.easeInOut(duration: 0.18), value: isExpanded)
  }

  @ViewBuilder
  private func content(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    VStack(spacing: 0) {
      collapsedHeader(coordinator)
      if isExpanded {
        Divider().opacity(0.4)
        detailList(coordinator)
      }
    }
    .background(.bar)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.6)
    }
  }

  // MARK: - Collapsed header

  private func collapsedHeader(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    HStack(spacing: 10) {
      headlineIcon(coordinator)

      Text(headline(coordinator))
        .font(.system(.subheadline, weight: .medium))
        .lineLimit(1)
        .layoutPriority(1)

      aggregateBar(coordinator)
        .frame(maxWidth: 220)

      Text("\(Int(coordinator.aggregateProgress * 100))%")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .monospacedDigit()

      Button {
        isExpanded.toggle()
      } label: {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Hide details" : "Show details")
    }
    .padding(.horizontal, 14)
    .frame(height: AgentHubLayout.topBarHeight)
    .contentShape(Rectangle())
    .onTapGesture { isExpanded.toggle() }
  }

  @ViewBuilder
  private func headlineIcon(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    if coordinator.inFlightCount > 0 {
      ProgressView()
        .controlSize(.small)
        .scaleEffect(0.7)
        .frame(width: 16, height: 16)
    } else if coordinator.hasFailures {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(width: 16, height: 16)
    } else {
      Image(systemName: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
        .frame(width: 16, height: 16)
    }
  }

  private func aggregateBar(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.gray.opacity(0.2))
        RoundedRectangle(cornerRadius: 2)
          .fill(coordinator.hasFailures ? Color.orange : Color.brandPrimary)
          .frame(width: geometry.size.width * min(coordinator.aggregateProgress, 1.0))
          .animation(.linear(duration: 0.15), value: coordinator.aggregateProgress)
      }
    }
    .frame(height: 4)
  }

  private func headline(_ coordinator: WorktreeGenerationProgressCoordinator) -> String {
    let inFlight = coordinator.inFlightCount
    if inFlight > 0 {
      return inFlight == 1 ? "Creating worktree…" : "Creating \(inFlight) worktrees…"
    }
    if coordinator.hasFailures {
      return "Worktree creation failed"
    }
    let done = coordinator.operations.count
    return done == 1 ? "Worktree ready" : "Worktrees ready"
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
    .frame(maxHeight: 220)
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

        // Naming has no meaningful percentage — show an indeterminate bar.
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
