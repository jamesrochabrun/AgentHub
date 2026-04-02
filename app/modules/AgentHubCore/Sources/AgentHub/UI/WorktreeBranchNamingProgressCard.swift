//
//  WorktreeBranchNamingProgressCard.swift
//  AgentHub
//

import SwiftUI

struct WorktreeBranchNamingProgressCard: View {
  let progress: WorktreeBranchNamingProgress
  let startedAt: Date?
  let finishedAt: Date?

  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var completionAnimationToken = 0
  @State private var lastCompletionSignature: String?

  var body: some View {
    Group {
      if progress.isVisible, let startedAt {
        VStack(alignment: .leading, spacing: 10) {
          header(startedAt: startedAt)
          stepsRow

          if !progress.resolvedBranchNames.isEmpty {
            branchNamesSection
          }
        }
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .fill(cardBackground)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
            .stroke(accentColor.opacity(progress.isInProgress ? 0.24 : 0.18), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.18), value: progress)
        .onAppear(perform: updateCompletionAnimation)
        .onChange(of: progress) { _, _ in
          updateCompletionAnimation()
        }
      }
    }
  }

  private func header(startedAt: Date) -> some View {
    HStack(alignment: .top, spacing: 10) {
      ZStack {
        Circle()
          .fill(accentColor.opacity(0.14))
          .frame(width: 30, height: 30)

        if progress.isInProgress {
          ProgressView()
            .scaleEffect(0.52)
            .tint(accentColor)
        } else {
          Image(systemName: leadingIcon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(accentColor)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.bounce, value: completionAnimationToken)
        }
      }
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(titleText)
          .font(.geist(size: 12, weight: .semibold))
          .foregroundStyle(.primary)

        Text(progress.message)
          .font(.secondarySmall)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .layoutPriority(1)

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 6) {
        statusBadge
          .fixedSize(horizontal: true, vertical: true)

        elapsedBadge(startedAt: startedAt)
          .fixedSize(horizontal: true, vertical: true)
      }
    }
  }

  private var statusBadge: some View {
    Group {
      if progress.isInProgress {
        badge(text: "Generating", systemImage: "waveform.path", tint: accentColor)
      } else if case .cancelled = progress {
        badge(text: "Cancelled", systemImage: "stop.circle.fill", tint: accentColor)
      } else if progress.isFallbackCompletion {
        badge(text: "Fallback", systemImage: "arrow.uturn.backward.circle", tint: accentColor)
      } else if progress.isFinished {
        badge(text: "Ready", systemImage: "checkmark.circle.fill", tint: accentColor)
      }
    }
  }

  private var stepsRow: some View {
    HStack(spacing: 6) {
      stepPill(index: 0, label: "Context", systemImage: "tray.and.arrow.down")
      stepPill(index: 1, label: "Generate", systemImage: "wand.and.rays")
      stepPill(index: 2, label: "Finalize", systemImage: "checklist")
      Spacer(minLength: 0)
    }
  }

  private var branchNamesSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(progress.resolvedBranchNames.count > 1 ? "Resolved branch names" : "Resolved branch name")
          .font(.geist(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 6) {
        ForEach(progress.resolvedBranchNames, id: \.self) { branchName in
          HStack(spacing: 6) {
            Image(systemName: "link")
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(accentColor.opacity(0.9))

            Text(branchName)
              .font(.jetBrainsMono(size: 10, weight: .medium))
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)

            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.primary.opacity(0.04))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.borderSubtle.opacity(0.08), lineWidth: 1)
          )
        }
      }
    }
  }

  private func badge(text: String, systemImage: String, tint: Color) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage)
        .font(.system(size: 8, weight: .semibold))
      Text(text)
        .font(.geist(size: 9, weight: .semibold))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(
      Capsule()
        .fill(tint.opacity(0.12))
    )
  }

  private func elapsedBadge(startedAt: Date) -> some View {
    TimelineView(.periodic(from: startedAt, by: 0.2)) { context in
      let endDate = finishedAt ?? context.date
      let elapsed = max(0, endDate.timeIntervalSince(startedAt))

      HStack(spacing: 4) {
        Image(systemName: "timer")
          .font(.system(size: 8, weight: .semibold))
        Text(String(format: "%.1fs", elapsed))
          .font(.geist(size: 9, weight: .semibold))
          .monospacedDigit()
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(Color.primary.opacity(0.06))
      )
      .accessibilityLabel("Elapsed branch naming time")
      .accessibilityValue(String(format: "%.1f seconds", elapsed))
    }
  }

  private func stepPill(index: Int, label: String, systemImage: String) -> some View {
    let currentStep = progress.currentStepIndex ?? 0
    let isFailed = isFailedStep(index: index)
    let isActive = progress.isInProgress && currentStep == index
    let isComplete = isCompletedStep(index: index)
    let tint: Color = {
      if isFailed { return .red }
      if isActive || isComplete { return accentColor }
      return .secondary.opacity(0.6)
    }()

    return HStack(spacing: 4) {
      Group {
        if isComplete {
          Image(systemName: "checkmark.circle.fill")
        } else if isFailed {
          Image(systemName: "exclamationmark.circle.fill")
        } else {
          Image(systemName: systemImage)
        }
      }
      .font(.system(size: 9, weight: .semibold))

      Text(label)
        .font(.geist(size: 9, weight: .medium))
        .lineLimit(1)
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      Capsule()
        .fill(
          (isActive || isComplete ? tint : Color.primary.opacity(0.05))
            .opacity(isActive || isComplete ? 0.14 : 1)
        )
    )
    .overlay(
      Capsule()
        .stroke(tint.opacity(isActive || isComplete || isFailed ? 0.18 : 0.08), lineWidth: 1)
    )
  }

  private var titleText: String {
    switch progress {
    case .idle:
      return ""
    case .preparingContext:
      return "Preparing branch name"
    case .queryingModel:
      return "Generating branch name"
    case .sanitizing:
      return "Finalizing branch name"
    case .completed(_, .ai, _):
      return "Branch name ready"
    case .completed(_, .deterministicFallback, _):
      return "Fallback branch name ready"
    case .cancelled:
      return "Branch naming cancelled"
    case .failed:
      return "Branch naming failed"
    }
  }

  private var leadingIcon: String {
    switch progress {
    case .idle, .preparingContext, .queryingModel, .sanitizing:
      return "sparkles"
    case .completed:
      return "checkmark.circle.fill"
    case .cancelled:
      return "stop.circle.fill"
    case .failed:
      return "xmark.octagon.fill"
    }
  }

  private var accentColor: Color {
    switch progress {
    case .completed(_, .deterministicFallback, _):
      return .orange
    case .cancelled:
      return .secondary
    case .failed:
      return .red
    case .idle, .preparingContext, .queryingModel, .sanitizing, .completed:
      return .brandPrimary
    }
  }

  private var cardBackground: LinearGradient {
    LinearGradient(
      colors: [
        accentColor.opacity(0.11),
        accentColor.opacity(0.04),
        Color.surfaceOverlay
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private func isCompletedStep(index: Int) -> Bool {
    switch progress {
    case .completed:
      return true
    case .cancelled:
      return false
    case .failed:
      return index < (progress.currentStepIndex ?? 0)
    default:
      return index < (progress.currentStepIndex ?? 0)
    }
  }

  private func isFailedStep(index: Int) -> Bool {
    guard case .failed = progress else { return false }
    return index == (progress.currentStepIndex ?? 0)
  }

  private func updateCompletionAnimation() {
    guard progress.isFinished else { return }

    let signature = [
      progress.message,
      progress.source?.rawValue ?? {
        if case .cancelled = progress {
          return "cancelled"
        }
        return "failed"
      }(),
      progress.resolvedBranchNames.joined(separator: "|")
    ].joined(separator: "::")

    guard signature != lastCompletionSignature else { return }
    lastCompletionSignature = signature

    guard !accessibilityReduceMotion else { return }
    completionAnimationToken += 1
  }
}
