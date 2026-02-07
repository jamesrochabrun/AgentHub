//
//  MultiSessionLaunchViewModel.swift
//  AgentHub
//
//  View model for the Session Launcher.
//  Coordinates creating worktrees and starting sessions for Claude, Codex, or both.
//

import Foundation

// MARK: - LaunchProviderMode

public enum LaunchProviderMode: String, CaseIterable, Sendable {
  case claude = "Claude"
  case codex = "Codex"
  case both = "Both"
}

// MARK: - MultiSessionLaunchViewModel

@MainActor
@Observable
public final class MultiSessionLaunchViewModel {

  // MARK: - Dependencies

  private let claudeViewModel: CLISessionsViewModel
  private let codexViewModel: CLISessionsViewModel
  private let worktreeService: GitWorktreeService

  // MARK: - Form State

  public var selectedProviderMode: LaunchProviderMode = .both
  public var sharedPrompt: String = ""
  public var branchInput: String = ""
  public var claudeBranchName: String = ""
  public var codexBranchName: String = ""
  public var singleBranchName: String = ""
  public var baseBranch: RemoteBranch?
  public var selectedRepository: SelectedRepository?

  // MARK: - Loaded Data

  public var availableBranches: [RemoteBranch] = []
  public var isLoadingBranches: Bool = false

  // MARK: - Launch State

  public var isLaunching: Bool = false
  public var claudeProgress: WorktreeCreationProgress = .idle
  public var codexProgress: WorktreeCreationProgress = .idle
  public var launchError: String?

  // MARK: - Callbacks

  public var onLaunchCompleted: (() -> Void)?

  // MARK: - Computed

  public var isValid: Bool {
    let hasPrompt = !sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasRepo = selectedRepository != nil

    switch selectedProviderMode {
    case .both:
      return hasPrompt && hasRepo && !claudeBranchName.isEmpty && !codexBranchName.isEmpty
    case .claude, .codex:
      return hasPrompt && hasRepo && !singleBranchName.isEmpty
    }
  }

  // MARK: - Init

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    worktreeService: GitWorktreeService = GitWorktreeService()
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.worktreeService = worktreeService
  }

  // MARK: - Actions

  /// Loads local branches for the selected repository
  public func loadBranches() async {
    guard let repo = selectedRepository else { return }
    isLoadingBranches = true

    do {
      availableBranches = try await worktreeService.getLocalBranches(at: repo.path)
      if let first = availableBranches.first {
        baseBranch = first
      }
    } catch {
      availableBranches = []
    }

    isLoadingBranches = false
  }

  /// Updates branch names based on the current provider mode
  public func updateBranchNames(from input: String) {
    branchInput = input
    let sanitized = GitWorktreeService.sanitizeBranchName(input)
    guard !sanitized.isEmpty else {
      claudeBranchName = ""
      codexBranchName = ""
      singleBranchName = ""
      return
    }

    switch selectedProviderMode {
    case .both:
      claudeBranchName = "\(sanitized)-claude"
      codexBranchName = "\(sanitized)-codex"
      singleBranchName = ""
    case .claude, .codex:
      singleBranchName = sanitized
      claudeBranchName = ""
      codexBranchName = ""
    }
  }

  /// Re-apply branch names when provider mode changes
  public func onProviderModeChanged() {
    if !branchInput.isEmpty {
      updateBranchNames(from: branchInput)
    }
  }

  /// Directory name for a given branch name in the selected repository
  public func directoryName(for branchName: String) -> String {
    guard let repo = selectedRepository else { return branchName }
    return GitWorktreeService.worktreeDirectoryName(for: branchName, repoName: repo.name)
  }

  /// Creates worktrees and starts sessions based on the selected provider mode
  public func launchSessions() async {
    guard let repo = selectedRepository, isValid else { return }

    isLaunching = true
    launchError = nil
    claudeProgress = .idle
    codexProgress = .idle

    let prompt = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let repoPath = repo.path

    switch selectedProviderMode {
    case .both:
      await launchBothProviders(prompt: prompt, repoPath: repoPath)
    case .claude:
      await launchSingleProvider(
        prompt: prompt,
        repoPath: repoPath,
        branchName: singleBranchName,
        viewModel: claudeViewModel,
        progressSetter: { self.claudeProgress = $0 }
      )
    case .codex:
      await launchSingleProvider(
        prompt: prompt,
        repoPath: repoPath,
        branchName: singleBranchName,
        viewModel: codexViewModel,
        progressSetter: { self.codexProgress = $0 }
      )
    }

    isLaunching = false
    onLaunchCompleted?()
    reset()
  }

  /// Resets all form fields to initial state
  public func reset() {
    sharedPrompt = ""
    branchInput = ""
    claudeBranchName = ""
    codexBranchName = ""
    singleBranchName = ""
    baseBranch = availableBranches.first
    claudeProgress = .idle
    codexProgress = .idle
    launchError = nil
  }

  // MARK: - Private

  private func launchBothProviders(prompt: String, repoPath: String) async {
    // Ensure the repository is added to both providers
    claudeViewModel.addRepository(at: repoPath)
    codexViewModel.addRepository(at: repoPath)
    try? await Task.sleep(for: .milliseconds(300))

    // 1. Create Claude worktree
    var claudeWorktreePath: String?
    do {
      let dirName = directoryName(for: claudeBranchName)
      claudeWorktreePath = try await worktreeService.createWorktreeWithNewBranch(
        at: repoPath,
        newBranchName: claudeBranchName,
        directoryName: dirName,
        startPoint: baseBranch?.displayName
      ) { [weak self] progress in
        Task { @MainActor in
          self?.claudeProgress = progress
        }
      }
    } catch {
      claudeProgress = .failed(error: error.localizedDescription)
      launchError = "Claude worktree: \(error.localizedDescription)"
    }

    // 2. Create Codex worktree
    var codexWorktreePath: String?
    do {
      let dirName = directoryName(for: codexBranchName)
      codexWorktreePath = try await worktreeService.createWorktreeWithNewBranch(
        at: repoPath,
        newBranchName: codexBranchName,
        directoryName: dirName,
        startPoint: baseBranch?.displayName
      ) { [weak self] progress in
        Task { @MainActor in
          self?.codexProgress = progress
        }
      }
    } catch {
      codexProgress = .failed(error: error.localizedDescription)
      let msg = "Codex worktree: \(error.localizedDescription)"
      launchError = launchError != nil ? "\(launchError!)\n\(msg)" : msg
    }

    guard claudeWorktreePath != nil || codexWorktreePath != nil else { return }

    // 3. Refresh and start sessions
    claudeViewModel.refresh()
    codexViewModel.refresh()
    try? await Task.sleep(for: .milliseconds(500))

    if let path = claudeWorktreePath {
      let worktree = WorktreeBranch(name: claudeBranchName, path: path, isWorktree: true)
      claudeViewModel.startNewSessionInHub(worktree, initialPrompt: prompt)
    }

    try? await Task.sleep(for: .milliseconds(800))

    if let path = codexWorktreePath {
      let worktree = WorktreeBranch(name: codexBranchName, path: path, isWorktree: true)
      codexViewModel.startNewSessionInHub(worktree, initialPrompt: prompt)
    }

    claudeViewModel.refresh()
    codexViewModel.refresh()
  }

  private func launchSingleProvider(
    prompt: String,
    repoPath: String,
    branchName: String,
    viewModel: CLISessionsViewModel,
    progressSetter: @escaping (WorktreeCreationProgress) -> Void
  ) async {
    viewModel.addRepository(at: repoPath)
    try? await Task.sleep(for: .milliseconds(300))

    var worktreePath: String?
    do {
      let dirName = directoryName(for: branchName)
      worktreePath = try await worktreeService.createWorktreeWithNewBranch(
        at: repoPath,
        newBranchName: branchName,
        directoryName: dirName,
        startPoint: baseBranch?.displayName
      ) { progress in
        Task { @MainActor in
          progressSetter(progress)
        }
      }
    } catch {
      progressSetter(.failed(error: error.localizedDescription))
      launchError = error.localizedDescription
      return
    }

    guard let path = worktreePath else { return }

    viewModel.refresh()
    try? await Task.sleep(for: .milliseconds(500))

    let worktree = WorktreeBranch(name: branchName, path: path, isWorktree: true)
    viewModel.startNewSessionInHub(worktree, initialPrompt: prompt)
    viewModel.refresh()
  }
}
