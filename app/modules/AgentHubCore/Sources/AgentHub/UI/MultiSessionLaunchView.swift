//
//  MultiSessionLaunchView.swift
//  AgentHub
//
//  Collapsible panel for launching dual Claude + Codex sessions
//  with a shared prompt and separate worktree branches.
//

import SwiftUI

// MARK: - MultiSessionLaunchView

public struct MultiSessionLaunchView: View {
  @Bindable var viewModel: MultiSessionLaunchViewModel
  @Binding var isExpanded: Bool
  let allRepositories: [SelectedRepository]

  @State private var branchInput: String = ""
  @Environment(\.colorScheme) private var colorScheme

  public var body: some View {
    if isExpanded {
      expandedForm
    } else {
      collapsedButton
    }
  }

  // MARK: - Collapsed

  private var collapsedButton: some View {
    Button(action: {
      withAnimation(.easeInOut(duration: 0.25)) {
        isExpanded = true
      }
    }) {
      HStack(spacing: 8) {
        Image(systemName: "rectangle.split.2x1")
          .font(.system(size: DesignTokens.IconSize.md))
          .foregroundColor(.secondary)
        Text("Multi-Session")
          .font(.system(size: 13))
          .foregroundColor(.secondary)
        Spacer()
        Image(systemName: "chevron.down")
          .font(.system(size: 10))
          .foregroundColor(.secondary.opacity(0.6))
      }
      .padding(.horizontal, DesignTokens.Spacing.md)
      .padding(.vertical, DesignTokens.Spacing.sm)
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

  // MARK: - Expanded Form

  private var expandedForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Header
      formHeader

      Divider()

      // Repository picker
      repositoryPicker

      // Prompt textarea
      promptEditor

      // Branch name input
      branchInputField

      // Branch names (auto-generated, read-only display)
      if !viewModel.claudeBranchName.isEmpty {
        branchPreview
      }

      // Base branch picker
      if !viewModel.availableBranches.isEmpty {
        baseBranchPicker
      }

      // Progress section
      if viewModel.isLaunching {
        progressSection
      }

      // Error display
      if let error = viewModel.launchError {
        errorView(error)
      }

      Divider()

      // Action buttons
      actionButtons
    }
    .padding(DesignTokens.Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .fill(Color.surfaceOverlay)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
        .stroke(Color.borderSubtle, lineWidth: 1)
    )
  }

  // MARK: - Header

  private var formHeader: some View {
    HStack {
      Image(systemName: "rectangle.split.2x1")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(.primary)
      Text("Multi-Session")
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      Button(action: {
        withAnimation(.easeInOut(duration: 0.25)) {
          isExpanded = false
        }
      }) {
        Image(systemName: "chevron.up")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Repository Picker

  private var repositoryPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Repository")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      Picker("Repository", selection: $viewModel.selectedRepository) {
        Text("Select...").tag(nil as SelectedRepository?)
        ForEach(allRepositories) { repo in
          Text(repo.name).tag(repo as SelectedRepository?)
        }
      }
      .pickerStyle(.menu)
      .onChange(of: viewModel.selectedRepository) { _, _ in
        Task {
          await viewModel.loadBranches()
        }
        // Re-apply branch names with new repo context
        if !branchInput.isEmpty {
          viewModel.updateBranchNames(from: branchInput)
        }
      }
    }
  }

  // MARK: - Prompt Editor

  private var promptEditor: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Prompt")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      ZStack(alignment: .topLeading) {
        if viewModel.sharedPrompt.isEmpty {
          Text("Enter shared prompt for both sessions...")
            .font(.system(size: 12))
            .foregroundColor(.secondary.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
        TextEditor(text: $viewModel.sharedPrompt)
          .font(.system(size: 12))
          .scrollContentBackground(.hidden)
          .padding(.horizontal, 2)
          .padding(.vertical, 2)
      }
      .frame(minHeight: 60, maxHeight: 120)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
          .fill(Color(NSColor.controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
          .stroke(Color.borderSubtle, lineWidth: 1)
      )
    }
  }

  // MARK: - Branch Input

  private var branchInputField: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Branch Name")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      TextField("feature/my-feature", text: $branchInput)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 12))
        .onChange(of: branchInput) { _, newValue in
          viewModel.updateBranchNames(from: newValue)
        }

      Text("Suffixed with -claude and -codex automatically")
        .font(.caption2)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Branch Preview

  private var branchPreview: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.branch")
          .font(.caption)
          .foregroundColor(.primary)
        Text("Branches")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundColor(.primary)
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text("Claude")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: 40, alignment: .trailing)
          Text(viewModel.claudeBranchName)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.primary)
        }
        HStack(spacing: 6) {
          Text("Codex")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.secondary)
            .frame(width: 40, alignment: .trailing)
          Text(viewModel.codexBranchName)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.primary)
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color.primary.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
    )
  }

  // MARK: - Base Branch Picker

  private var baseBranchPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Based On")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      if viewModel.isLoadingBranches {
        HStack(spacing: 8) {
          ProgressView()
            .scaleEffect(0.7)
          Text("Loading branches...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      } else {
        Picker("Based On", selection: $viewModel.baseBranch) {
          Text("Current HEAD").tag(nil as RemoteBranch?)
          ForEach(viewModel.availableBranches) { branch in
            Text(branch.displayName).tag(branch as RemoteBranch?)
          }
        }
        .pickerStyle(.menu)
      }
    }
  }

  // MARK: - Progress

  private var progressSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      progressRow(label: "Claude", progress: viewModel.claudeProgress)
      progressRow(label: "Codex", progress: viewModel.codexProgress)
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color.primary.opacity(0.03))
    )
  }

  private func progressRow(label: String, progress: WorktreeCreationProgress) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .frame(width: 40, alignment: .trailing)

      if progress.isInProgress {
        ProgressView(value: progress.progressValue)
          .tint(.primary)
      } else {
        Image(systemName: progress.icon)
          .font(.caption)
          .foregroundColor(progressIconColor(for: progress))
      }

      Text(progress.statusMessage)
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)

      Spacer()
    }
  }

  private func progressIconColor(for progress: WorktreeCreationProgress) -> Color {
    switch progress {
    case .completed:
      return .green
    case .failed:
      return .red
    default:
      return .secondary
    }
  }

  // MARK: - Error

  private func errorView(_ error: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundColor(.orange)
      Text(error)
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(3)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
        .fill(Color.orange.opacity(0.1))
    )
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    HStack {
      Button("Cancel") {
        withAnimation(.easeInOut(duration: 0.25)) {
          viewModel.reset()
          branchInput = ""
          isExpanded = false
        }
      }
      .disabled(viewModel.isLaunching)

      Spacer()

      Button(action: {
        Task {
          await viewModel.launchBothSessions()
        }
      }) {
        HStack(spacing: 6) {
          if viewModel.isLaunching {
            ProgressView()
              .scaleEffect(0.7)
          }
          Text(viewModel.isLaunching ? "Launching..." : "Launch")
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(.primary)
      .disabled(!viewModel.isValid || viewModel.isLaunching)
    }
  }
}
