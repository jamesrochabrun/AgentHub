//
//  MultiSessionLaunchViewModel.swift
//  AgentHub
//
//  View model for the Multi-Session Launch feature.
//  Coordinates creating worktrees and starting sessions for both Claude and Codex.
//

import Foundation

// MARK: - MultiSessionLaunchViewModel

@MainActor
@Observable
public final class MultiSessionLaunchViewModel {

  // MARK: - Dependencies

  private let claudeViewModel: CLISessionsViewModel
  private let codexViewModel: CLISessionsViewModel
  private let worktreeService: GitWorktreeService

  // MARK: - Form State

  public var sharedPrompt: String = ""
  public var claudeBranchName: String = ""
  public var codexBranchName: String = ""
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
    !sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    && !claudeBranchName.isEmpty
    && !codexBranchName.isEmpty
    && selectedRepository != nil
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

  /// Updates branch names with the repo-name prefix and provider suffix
  public func updateBranchNames(from input: String) {
    guard let repo = selectedRepository else { return }
    let repoName = repo.name
    let sanitized = GitWorktreeService.sanitizeBranchName(input)
    guard !sanitized.isEmpty else {
      claudeBranchName = ""
      codexBranchName = ""
      return
    }
    claudeBranchName = "\(sanitized)-claude"
    codexBranchName = "\(sanitized)-codex"
  }

  /// Directory name for a given branch name in the selected repository
  public func directoryName(for branchName: String) -> String {
    guard let repo = selectedRepository else { return branchName }
    return GitWorktreeService.worktreeDirectoryName(for: branchName, repoName: repo.name)
  }

  /// Creates worktrees for both providers and starts sessions with the shared prompt
  public func launchBothSessions() async {
    guard let repo = selectedRepository, isValid else { return }

    isLaunching = true
    launchError = nil
    claudeProgress = .idle
    codexProgress = .idle

    let prompt = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let repoPath = repo.path

    // Ensure the repository is added to both providers
    claudeViewModel.addRepository(at: repoPath)
    codexViewModel.addRepository(at: repoPath)

    // Brief pause to let addRepository complete
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

    // If both failed, stop
    guard claudeWorktreePath != nil || codexWorktreePath != nil else {
      isLaunching = false
      return
    }

    // 3. Refresh both view models to pick up new worktrees
    claudeViewModel.refresh()
    codexViewModel.refresh()

    // Brief pause for refresh to complete
    try? await Task.sleep(for: .milliseconds(500))

    // 4. Start Claude session
    if let path = claudeWorktreePath {
      let worktree = WorktreeBranch(
        name: claudeBranchName,
        path: path,
        isWorktree: true
      )
      claudeViewModel.startNewSessionInHub(worktree, initialPrompt: prompt)
    }

    // 800ms delay between launches (matching WorktreeOrchestrationService)
    try? await Task.sleep(for: .milliseconds(800))

    // 5. Start Codex session
    if let path = codexWorktreePath {
      let worktree = WorktreeBranch(
        name: codexBranchName,
        path: path,
        isWorktree: true
      )
      codexViewModel.startNewSessionInHub(worktree, initialPrompt: prompt)
    }

    // 6. Refresh again to show sessions
    claudeViewModel.refresh()
    codexViewModel.refresh()

    isLaunching = false
    onLaunchCompleted?()
    reset()
  }

  /// Resets all form fields to initial state
  public func reset() {
    sharedPrompt = ""
    claudeBranchName = ""
    codexBranchName = ""
    baseBranch = availableBranches.first
    claudeProgress = .idle
    codexProgress = .idle
    launchError = nil
  }
}
