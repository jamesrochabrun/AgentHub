//
//  MultiSessionLaunchView.swift
//  AgentHub
//
//  Always-visible session launcher for starting Claude, Codex, or both
//  with a shared prompt. Supports local mode and worktree mode.
//

import SwiftUI

// MARK: - MultiSessionLaunchView

public struct MultiSessionLaunchView: View {
  @Bindable var viewModel: MultiSessionLaunchViewModel

  @Environment(\.colorScheme) private var colorScheme
  @State private var isExpanded = false

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      formHeader

      if isExpanded {
        Divider()

        repositorySection

        promptEditor

        if viewModel.selectedRepository != nil {
          workModeRow
        }

        providerPills

        if viewModel.isLaunching {
          progressSection
        }

        if let error = viewModel.launchError {
          errorView(error)
        }

        Divider()

        actionButtons
      }
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
    .onChange(of: viewModel.isLaunching) { wasLaunching, isLaunching in
      if wasLaunching && !isLaunching {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded = false
        }
      }
    }
  }

  // MARK: - Header

  private var formHeader: some View {
    HStack {
      Text("Start Project")
        .font(.system(size: 13, weight: .bold, design: .monospaced))
      Spacer()
      Button(action: {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      }) {
        Image(systemName: isExpanded ? "minus.circle" : "plus.circle")
          .font(.system(size: 16))
          .foregroundColor(.secondary)
      }
      .buttonStyle(.plain)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(.easeInOut(duration: 0.2)) {
        isExpanded.toggle()
      }
    }
    .padding(.top, 6)
    .padding(.bottom, 6)
    .padding(.leading, 6)
  }

  // MARK: - Repository Section

  private var repositorySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: { viewModel.selectRepository() }) {
        HStack(spacing: 6) {
          Image(systemName: "folder")
            .font(.system(size: 11))
          Text(viewModel.selectedRepository?.name ?? "Select repository")
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
          Capsule()
            .fill(viewModel.selectedRepository != nil
                  ? Color.primary.opacity(0.1)
                  : Color.primary.opacity(0.05))
        )
        .overlay(
          Capsule()
            .stroke(Color.borderSubtle, lineWidth: 1)
        )
      }
      .buttonStyle(.plain)

      if let repo = viewModel.selectedRepository {
        Text(repo.path)
          .font(.system(size: 10, design: .monospaced))
          .foregroundColor(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  // MARK: - Prompt Editor

  private var promptEditor: some View {
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

  private var promptPlaceholder: String {
    if viewModel.isClaudeSelected && viewModel.isCodexSelected {
      return "Enter prompt for both sessions..."
    } else if viewModel.isClaudeSelected {
      return "Enter prompt for Claude session..."
    } else if viewModel.isCodexSelected {
      return "Enter prompt for Codex session..."
    } else {
      return "Select a provider..."
    }
  }

  // MARK: - Work Mode Row

  private var workModeRow: some View {
    HStack(spacing: 0) {
      // Left: Local / Worktree toggle
      HStack(spacing: 12) {
        workModeButton(mode: .local, label: "Local")
        workModeButton(mode: .worktree, label: "Worktree")
      }

      Spacer()

      // Right: branch info
      branchInfoView
    }
  }

  private func workModeButton(mode: WorkMode, label: String) -> some View {
    Button(action: {
      withAnimation(.easeInOut(duration: 0.2)) {
        viewModel.workMode = mode
      }
    }) {
      Text(label)
        .font(.system(size: 11, weight: viewModel.workMode == mode ? .bold : .regular))
        .foregroundColor(viewModel.workMode == mode ? .primary : .secondary.opacity(0.6))
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var branchInfoView: some View {
    switch viewModel.workMode {
    case .local:
      HStack(spacing: 4) {
        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: 10))
          .foregroundColor(.secondary)
        if viewModel.isLoadingCurrentBranch {
          ProgressView()
            .scaleEffect(0.5)
            .frame(width: 12, height: 12)
        } else {
          Text(viewModel.currentBranchName.isEmpty ? "—" : viewModel.currentBranchName)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }
    case .worktree:
      if viewModel.isLoadingBranches {
        HStack(spacing: 4) {
          ProgressView()
            .scaleEffect(0.5)
            .frame(width: 12, height: 12)
          Text("Loading...")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      } else {
        Picker("Base", selection: $viewModel.baseBranch) {
          Text("Current HEAD").tag(nil as RemoteBranch?)
          ForEach(viewModel.availableBranches) { branch in
            Text(branch.displayName).tag(branch as RemoteBranch?)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
    }
  }

  // MARK: - Provider Pills

  private var providerPills: some View {
    HStack(spacing: 8) {
      providerPill(
        label: "Claude",
        isSelected: $viewModel.isClaudeSelected
      )
      providerPill(
        label: "Codex",
        isSelected: $viewModel.isCodexSelected
      )
      Spacer()
    }
  }

  private func providerPill(label: String, isSelected: Binding<Bool>) -> some View {
    Button(action: { isSelected.wrappedValue.toggle() }) {
      Text(label)
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(isSelected.wrappedValue ? (colorScheme == .dark ? .black : .white) : .secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
          Capsule()
            .fill(isSelected.wrappedValue ? (colorScheme == .dark ? Color.white : Color.black) : Color.primary.opacity(0.06))
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Progress

  private var progressSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      if viewModel.isClaudeSelected {
        progressRow(label: "Claude", progress: viewModel.claudeProgress)
      }
      if viewModel.isCodexSelected {
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
          Text(launchButtonTitle)
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(.primary)
      .disabled(!viewModel.isValid || viewModel.isLaunching)
    }
  }

  private var launchButtonTitle: String {
    if viewModel.isLaunching {
      return "Launching..."
    }
    return "Launch"
  }
}
