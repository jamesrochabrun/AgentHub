//
//  CreateWorktreeSheet.swift
//  AgentHub
//
//  Created by Assistant on 1/12/26.
//

import SwiftUI

// MARK: - CreateWorktreeSheet

/// Sheet view for creating a new git worktree with a new branch
public struct CreateWorktreeSheet: View {
  let repositoryPath: String
  let repositoryName: String
  let onDismiss: () -> Void
  let onCreate: (String, String, String?, @escaping @Sendable (WorktreeCreationProgress) async -> Void) async throws -> Void

  @State private var branchName: String = ""
  @State private var baseBranch: RemoteBranch?
  @State private var directoryName: String = ""
  @State private var availableBranches: [RemoteBranch] = []
  @State private var isLoading: Bool = true
  @State private var creationProgress: WorktreeCreationProgress = .idle
  @State private var errorMessage: String?
  @State private var showError: Bool = false

  private let worktreeService = GitWorktreeService()

  public init(
    repositoryPath: String,
    repositoryName: String,
    onDismiss: @escaping () -> Void,
    onCreate: @escaping (String, String, String?, @escaping @Sendable (WorktreeCreationProgress) async -> Void) async throws -> Void
  ) {
    self.repositoryPath = repositoryPath
    self.repositoryName = repositoryName
    self.onDismiss = onDismiss
    self.onCreate = onCreate
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      // Header
      headerSection

      Divider()

      if isLoading {
        loadingView
      } else {
        // Branch name field
        branchNameField

        // Base branch picker
        baseBranchPicker

        // Directory name field
        directoryField

        Divider()

        // Action buttons
        actionButtons
      }
    }
    .padding(20)
    .frame(width: 420)
    .task {
      await loadBranches()
    }
    .alert("Error", isPresented: $showError) {
      Button("OK") { showError = false }
    } message: {
      Text(errorMessage ?? "An unknown error occurred")
    }
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: "arrow.triangle.branch")
          .font(.title2)
          .foregroundColor(.brandPrimary)

        Text("Create Worktree")
          .font(.headline)

        Spacer()

        Button(action: onDismiss) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
      }

      HStack(spacing: 4) {
        Image(systemName: "folder.fill")
          .font(.caption)
          .foregroundColor(.secondary)
        Text(repositoryName)
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }

  // MARK: - Loading View

  private var loadingView: some View {
    HStack(spacing: 12) {
      ProgressView()
        .scaleEffect(0.8)
      Text("Loading branches...")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  // MARK: - Branch Name Field

  private var branchNameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Branch Name")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      TextField("feature/my-feature", text: $branchName)
        .textFieldStyle(.roundedBorder)
        .onChange(of: branchName) { _, newValue in
          directoryName = GitWorktreeService.sanitizeBranchName(newValue)
        }

      Text("A new branch will be created with this name")
        .font(.caption2)
        .foregroundColor(.secondary)
    }
  }

  // MARK: - Base Branch Picker

  private var baseBranchPicker: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Based On")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      Picker("Based On", selection: $baseBranch) {
        Text("Current HEAD").tag(nil as RemoteBranch?)
        ForEach(availableBranches) { branch in
          Text(branch.displayName).tag(branch as RemoteBranch?)
        }
      }
      .pickerStyle(.menu)

      Text(baseBranchDescription)
        .font(.caption2)
        .foregroundColor(.secondary)
    }
  }

  private var baseBranchDescription: String {
    if let branch = baseBranch {
      return "New branch will start from '\(branch.displayName)'"
    } else {
      return "New branch will start from current commit (HEAD)"
    }
  }

  // MARK: - Directory Field

  private var directoryField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Directory Name")
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(.secondary)

      TextField("worktree-directory", text: $directoryName)
        .textFieldStyle(.roundedBorder)

      // Path preview box
      pathPreviewBox
    }
  }

  private var pathPreviewBox: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "folder.badge.plus")
          .font(.caption)
          .foregroundColor(.brandPrimary)
        Text("Worktree Location")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundColor(.primary)
      }

      // Full path display
      VStack(alignment: .leading, spacing: 2) {
        Text(parentDirectory)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(.secondary)

        HStack(spacing: 0) {
          Text("/")
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
          Text(directoryName.isEmpty ? "<directory>" : directoryName)
            .font(.system(.subheadline, design: .monospaced))
            .fontWeight(.semibold)
            .foregroundColor(.brandPrimary)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.brandPrimary.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.brandPrimary.opacity(0.3), lineWidth: 1)
    )
  }

  // MARK: - Action Buttons

  private var actionButtons: some View {
    VStack(spacing: 12) {
      // Progress indicator (only show when creating)
      if creationProgress.isInProgress {
        worktreeProgressView
      }

      // Buttons
      HStack {
        Button("Cancel") {
          onDismiss()
        }
        .keyboardShortcut(.escape)
        .disabled(creationProgress.isInProgress)

        Spacer()

        Button(action: { Task { await createWorktree() } }) {
          HStack(spacing: 6) {
            if creationProgress.isInProgress {
              ProgressView()
                .scaleEffect(0.7)
            }
            Text(creationProgress.isInProgress ? "Creating..." : "Create Worktree")
          }
        }
        .keyboardShortcut(.return)
        .disabled(!isValid || creationProgress.isInProgress)
        .buttonStyle(.borderedProminent)
        .tint(.brandPrimary)
      }
    }
  }

  // MARK: - Progress View

  private var worktreeProgressView: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Progress bar with real file counts
      ProgressView(value: creationProgress.progressValue)
        .tint(.brandPrimary)
        .animation(.linear(duration: 0.1), value: creationProgress.progressValue)

      // Status message: "Updating files: 84/194"
      HStack {
        Image(systemName: creationProgress.icon)
          .font(.caption)
          .foregroundColor(.brandPrimary)

        Text(creationProgress.statusMessage)
          .font(.caption)
          .foregroundColor(.secondary)
          .monospacedDigit()

        Spacer()

        // Percentage
        Text("\(Int(creationProgress.progressValue * 100))%")
          .font(.caption)
          .foregroundColor(.secondary)
          .monospacedDigit()
      }
    }
    .padding(12)
    .background(Color.brandPrimary.opacity(0.05))
    .cornerRadius(8)
  }

  // MARK: - Computed Properties

  private var parentDirectory: String {
    (repositoryPath as NSString).deletingLastPathComponent
  }

  private var isValid: Bool {
    !branchName.isEmpty && !directoryName.isEmpty
  }

  // MARK: - Actions

  private func loadBranches() async {
    print("[CreateWorktreeSheet] loadBranches called for: \(repositoryPath)")
    isLoading = true

    do {
      // Load local branches for the "Based On" picker
      availableBranches = try await worktreeService.getLocalBranches(at: repositoryPath)
      print("[CreateWorktreeSheet] Loaded \(availableBranches.count) branches")

      // Auto-select the first branch (usually main) as default base
      if let firstBranch = availableBranches.first {
        baseBranch = firstBranch
      }
    } catch {
      print("[CreateWorktreeSheet] ERROR loading branches: \(error)")
      errorMessage = error.localizedDescription
      showError = true
    }

    isLoading = false
  }

  private func createWorktree() async {
    creationProgress = .preparing(message: "Preparing worktree...")

    do {
      try await onCreate(branchName, directoryName, baseBranch?.displayName) { [self] newProgress in
        await MainActor.run {
          self.creationProgress = newProgress
        }
      }

      // Brief delay to show completion state
      try? await Task.sleep(for: .milliseconds(500))
      onDismiss()
    } catch {
      creationProgress = .failed(error: error.localizedDescription)
      errorMessage = error.localizedDescription
      showError = true

      // Reset to idle after showing error
      try? await Task.sleep(for: .seconds(2))
      creationProgress = .idle
    }
  }
}

// MARK: - Preview

#Preview {
  CreateWorktreeSheet(
    repositoryPath: "/Users/james/git/ClaudeCodeUI",
    repositoryName: "ClaudeCodeUI",
    onDismiss: { print("Dismissed") },
    onCreate: { branch, directory, baseBranch, onProgress in
      print("Create worktree: branch=\(branch), directory=\(directory), baseBranch=\(baseBranch ?? "HEAD")")
      // Simulate progress
      await onProgress(.preparing(message: "Preparing worktree..."))
      try? await Task.sleep(for: .milliseconds(500))
      for i in stride(from: 0, through: 100, by: 10) {
        await onProgress(.updatingFiles(current: i, total: 100))
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  )
}
