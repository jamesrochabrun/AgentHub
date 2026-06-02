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
///
/// Counts and the single/multi summary are based on **creation** operations
/// only — the transient branch-naming step is shown as a display state but
/// never counted as a worktree.
public struct WorktreeGenerationProgressBar: View {
  @Environment(WorktreeGenerationProgressCoordinator.self) private var coordinator: WorktreeGenerationProgressCoordinator?
  @State private var isExpanded = false

  public init() {}

  public var body: some View {
    Group {
      if let coordinator, coordinator.isActive {
        card(coordinator)
          .padding(.horizontal, 12)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    // Whole-bar appear/dismiss; inner content (expand, rows) animates in card().
    .animation(.spring(response: 0.36, dampingFraction: 0.85), value: coordinator?.isActive ?? false)
    .onChange(of: coordinator?.isActive ?? false) { _, active in
      if !active { isExpanded = false }
    }
  }

  // MARK: - Derived state (creation ops are the real worktrees; naming is transient)

  private func creations(_ coordinator: WorktreeGenerationProgressCoordinator) -> [WorktreeGenerationOperation] {
    coordinator.operations.filter { $0.kind == .creation }
  }

  private func canExpand(_ coordinator: WorktreeGenerationProgressCoordinator) -> Bool {
    creations(coordinator).count > 1
  }

  private func anyInFlight(_ coordinator: WorktreeGenerationProgressCoordinator) -> Bool {
    coordinator.operations.contains { $0.progress.isInProgress }
  }

  private func creationInFlight(_ coordinator: WorktreeGenerationProgressCoordinator) -> Bool {
    creations(coordinator).contains { $0.progress.isInProgress }
  }

  /// True once at least one creation reports real file-checkout progress. Git
  /// emits no checkout progress over a pipe, so a creation can sit at the
  /// `.preparing` floor (5%) with no movement for the whole checkout; until real
  /// progress arrives we hide the numeric percentage so it doesn't read as
  /// "stuck at 5%".
  private func hasFileProgress(_ coordinator: WorktreeGenerationProgressCoordinator) -> Bool {
    creations(coordinator).contains {
      if case .updatingFiles = $0.progress { return true }
      return false
    }
  }

  /// Mean progress over the real worktrees, or the naming step before any
  /// creation exists.
  private func displayProgress(_ coordinator: WorktreeGenerationProgressCoordinator) -> Double {
    let set = creations(coordinator).isEmpty ? coordinator.operations : creations(coordinator)
    guard !set.isEmpty else { return 0 }
    return set.reduce(0.0) { $0 + $1.progress.progressValue } / Double(set.count)
  }

  // MARK: - Card

  private func card(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    VStack(spacing: 0) {
      header(coordinator)
      // Only multi-worktree batches expand; a single worktree is already shown
      // uniquely in the header.
      if isExpanded && canExpand(coordinator) {
        Divider().opacity(0.5)
        detailList(coordinator)
      }
    }
    .animation(.easeInOut(duration: 0.18), value: isExpanded)
    .animation(.easeInOut(duration: 0.2), value: creations(coordinator).count)
    // Flat: no background fill, border, rounded corners, or shadow — just the
    // content with the progress hairline along the bottom.
    .overlay(alignment: .bottom) {
      progressHairline(coordinator)
    }
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
            .foregroundStyle(coordinator.hasFailures ? Color.red.opacity(0.9) : Color.secondary)
            .lineLimit(coordinator.hasFailures ? 4 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .monospacedDigit()
            .help(subtitle)
        }
      }

      Spacer(minLength: 8)

      if creationInFlight(coordinator) && hasFileProgress(coordinator) {
        Text("\(Int(displayProgress(coordinator) * 100))%")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      if canExpand(coordinator) {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }

      if coordinator.hasFailures {
        Button {
          coordinator.dismissAllFailed()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      guard canExpand(coordinator) else { return }
      isExpanded.toggle()
    }
  }

  @ViewBuilder
  private func leadingIcon(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    if anyInFlight(coordinator) {
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
    let progress = displayProgress(coordinator)
    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        Rectangle().fill(Color.secondary.opacity(0.12))
        Rectangle()
          .fill(accent(coordinator))
          .frame(width: geo.size.width * min(max(progress, 0), 1))
          .animation(.linear(duration: 0.2), value: progress)
      }
    }
    .frame(height: 3)
    .opacity(anyInFlight(coordinator) ? 1 : 0.6)
  }

  // MARK: - Expanded detail

  private func detailList(_ coordinator: WorktreeGenerationProgressCoordinator) -> some View {
    ScrollView {
      VStack(spacing: 6) {
        ForEach(creations(coordinator)) { op in
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
    if coordinator.hasFailures && !anyInFlight(coordinator) { return .orange }
    if !anyInFlight(coordinator) { return .green }
    return .brandPrimary
  }

  private func summary(_ coordinator: WorktreeGenerationProgressCoordinator) -> (title: String, subtitle: String?) {
    let worktrees = creations(coordinator)

    // Before any worktree exists, the only operation is the naming step.
    if worktrees.isEmpty {
      if let naming = coordinator.operations.first(where: { $0.isNaming }) {
        return singleSummary(naming)
      }
      return ("Preparing worktree…", nil)
    }

    if worktrees.count == 1 {
      return singleSummary(worktrees[0])
    }

    let inFlight = worktrees.filter { $0.progress.isInProgress }.count
    if inFlight > 0 {
      return ("Creating \(inFlight) worktrees…", "\(worktrees.count) total")
    }
    if worktrees.contains(where: { $0.isFailure }) {
      return ("Worktree creation failed", nil)
    }
    return ("\(worktrees.count) worktrees ready", nil)
  }

  private func singleSummary(_ op: WorktreeGenerationOperation) -> (title: String, subtitle: String?) {
    if op.isNaming {
      if case .completed = op.progress {
        return ("Branch name ready", op.repoName)
      }
      if case .failed(let error) = op.progress {
        return ("Branch naming failed", error)
      }
      return ("Generating branch name", op.repoName.isEmpty ? op.progress.statusMessage : op.repoName)
    }
    switch op.progress {
    case .completed:
      return (op.branchName.isEmpty ? "Worktree ready" : op.branchName, "Ready")
    case .failed(let error):
      return (op.branchName.isEmpty ? "Creation failed" : op.branchName, error)
    case .cancelled:
      return (op.branchName.isEmpty ? "Cancelled" : op.branchName, "Cancelled")
    case .idle, .queued, .preparing, .updatingFiles:
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

        if showsIndeterminateProgress {
          // No determinate value yet (naming, or a checkout that git runs
          // silently over a pipe): animate so it reads as working, not stuck.
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
          .foregroundStyle(operation.isFailure ? Color.red.opacity(0.9) : .secondary)
          .lineLimit(operation.isFailure ? 4 : 1)
          .fixedSize(horizontal: false, vertical: true)
          .help(statusLine)
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

  /// Whether to show an indeterminate (animated) bar rather than a determinate
  /// value: the naming step, and any in-flight creation that hasn't reported
  /// real file-checkout progress yet (git is silent over a pipe, so `.preparing`
  /// would otherwise render as a frozen 5%).
  private var showsIndeterminateProgress: Bool {
    if isNaming { return operation.progress.isInProgress }
    switch operation.progress {
    case .idle, .queued, .preparing:
      return true
    case .updatingFiles, .completed, .failed, .cancelled:
      return false
    }
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
    case .idle, .queued, .preparing, .updatingFiles: return .brandPrimary
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
    // Only show a percentage once there's real, advancing file progress — a
    // `.preparing` floor over a silent pipe checkout would read as "stuck at 5%".
    if case .updatingFiles = operation.progress {
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
