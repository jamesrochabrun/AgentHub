//
//  MultiSessionLaunchView.swift
//  AgentHub
//
//  Always-visible session launcher for starting Claude, Codex, or both
//  with a shared prompt and auto-generated worktree branches.
//

import SwiftUI

// MARK: - MultiSessionLaunchView

public struct MultiSessionLaunchView: View {
  @Bindable var viewModel: MultiSessionLaunchViewModel
  let allRepositories: [SelectedRepository]

  @State private var branchInput: String = ""
  @Environment(\.colorScheme) private var colorScheme

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Header
      formHeader

      Divider()

      // Provider mode + Repository (side by side)
      HStack(spacing: 8) {
        providerModePicker
        repositoryPicker
      }

      // Prompt textarea
      promptEditor

      // Branch name input
      branchInputField

      // Branch preview (only for "Both" mode)
      if viewModel.selectedProviderMode == .both && !viewModel.claudeBranchName.isEmpty {
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
      Image(systemName: "play.rectangle")
        .font(.system(size: DesignTokens.IconSize.md))
        .foregroundColor(.primary)
      Text("Session Launcher")
        .font(.system(size: 13, weight: .semibold))
      Spacer()
    }
  }

  // MARK: - Provider Mode Picker

  private var providerModePicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Provider")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      Picker("Provider", selection: $viewModel.selectedProviderMode) {
        ForEach(LaunchProviderMode.allCases, id: \.self) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.menu)
      .onChange(of: viewModel.selectedProviderMode) { _, _ in
        viewModel.onProviderModeChanged()
      }
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
          Text(promptPlaceholder)
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

  private var promptPlaceholder: String {
    switch viewModel.selectedProviderMode {
    case .both: return "Enter prompt for both sessions..."
    case .claude: return "Enter prompt for Claude session..."
    case .codex: return "Enter prompt for Codex session..."
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

      Text(branchHintText)
        .font(.caption2)
        .foregroundColor(.secondary)
    }
  }

  private var branchHintText: String {
    switch viewModel.selectedProviderMode {
    case .both: return "Suffixed with -claude and -codex automatically"
    case .claude, .codex: return "Branch name for the worktree"
    }
  }

  // MARK: - Branch Preview (Both mode only)

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
      switch viewModel.selectedProviderMode {
      case .both:
        progressRow(label: "Claude", progress: viewModel.claudeProgress)
        progressRow(label: "Codex", progress: viewModel.codexProgress)
      case .claude:
        progressRow(label: "Claude", progress: viewModel.claudeProgress)
      case .codex:
        progressRow(label: "Codex", progress: viewModel.codexProgress)
      }
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
      Button("Reset") {
        viewModel.reset()
        branchInput = ""
      }
      .disabled(viewModel.isLaunching)

      Spacer()

      Button(action: {
        Task {
          await viewModel.launchSessions()
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
