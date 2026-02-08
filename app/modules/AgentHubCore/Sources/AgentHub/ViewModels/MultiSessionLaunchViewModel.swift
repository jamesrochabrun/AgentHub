//
//  MultiSessionLaunchViewModel.swift
//  AgentHub
//
//  View model for the Session Launcher.
//  Coordinates creating worktrees and starting sessions for Claude, Codex, or both.
//

import AppKit
import Foundation

// MARK: - WorkMode

public enum WorkMode: String, CaseIterable, Sendable {
  case local = "Local"
  case worktree = "Worktree"
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

  public var workMode: WorkMode = .local
  public var isClaudeSelected: Bool = true
  public var isCodexSelected: Bool = true
  public var sharedPrompt: String = ""
  public var claudeBranchName: String = ""
  public var codexBranchName: String = ""
  public var singleBranchName: String = ""
  public var baseBranch: RemoteBranch?
  public var selectedRepository: SelectedRepository?

  // MARK: - Loaded Data

  public var availableBranches: [RemoteBranch] = []
  public var isLoadingBranches: Bool = false
  public var currentBranchName: String = ""
  public var isLoadingCurrentBranch: Bool = false

  // MARK: - Launch State

  public var isLaunching: Bool = false
  public var claudeProgress: WorktreeCreationProgress = .idle
  public var codexProgress: WorktreeCreationProgress = .idle
  public var launchError: String?

  // MARK: - Callbacks

  public var onLaunchCompleted: (() -> Void)?

  // MARK: - Computed

  public var selectedProviders: [SessionProviderKind] {
    var providers: [SessionProviderKind] = []
    if isClaudeSelected { providers.append(.claude) }
    if isCodexSelected { providers.append(.codex) }
    return providers
  }

  public var hasAnyProviderSelected: Bool {
    isClaudeSelected || isCodexSelected
  }

  public var isValid: Bool {
    let hasPrompt = !sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasRepo = selectedRepository != nil
    return hasPrompt && hasRepo && hasAnyProviderSelected
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

  /// Opens an NSOpenPanel to select a repository directory
  public func selectRepository() {
    let panel = NSOpenPanel()
    panel.title = "Select Repository"
    panel.message = "Choose a git repository"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    if panel.runModal() == .OK, let url = panel.url {
      let path = url.path
      let name = url.lastPathComponent
      selectedRepository = SelectedRepository(
        path: path,
        name: name,
        worktrees: [],
        isExpanded: true
      )
      Task {
        await loadBranches()
      }
    }
  }

  /// Loads local branches for the selected repository and fetches current branch
  public func loadBranches() async {
    guard let repo = selectedRepository else { return }
    isLoadingBranches = true
    isLoadingCurrentBranch = true

    do {
      availableBranches = try await worktreeService.getLocalBranches(at: repo.path)
      if let first = availableBranches.first {
        baseBranch = first
      }
    } catch {
      availableBranches = []
    }

    do {
      currentBranchName = try await worktreeService.getCurrentBranch(at: repo.path)
    } catch {
      currentBranchName = ""
    }

    isLoadingBranches = false
    isLoadingCurrentBranch = false
  }

  /// Auto-generates branch names from prompt text + short UUID suffix
  public func autoGenerateBranchNames() {
    let prompt = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }

    // Take first few words from prompt, sanitize, and add short UUID
    let words = prompt.components(separatedBy: .whitespacesAndNewlines)
      .prefix(4)
      .joined(separator: "-")
    let sanitized = GitWorktreeService.sanitizeBranchName(words)
    let suffix = String(UUID().uuidString.prefix(6)).lowercased()
    let base = sanitized.isEmpty ? "session" : sanitized

    let providers = selectedProviders
    if providers.count > 1 {
      claudeBranchName = "\(base)-\(suffix)-claude"
      codexBranchName = "\(base)-\(suffix)-codex"
      singleBranchName = ""
    } else {
      singleBranchName = "\(base)-\(suffix)"
      claudeBranchName = ""
      codexBranchName = ""
    }
  }

  /// Directory name for a given branch name in the selected repository
  public func directoryName(for branchName: String) -> String {
    guard let repo = selectedRepository else { return branchName }
    return GitWorktreeService.worktreeDirectoryName(for: branchName, repoName: repo.name)
  }

  /// Creates worktrees and starts sessions based on the selected providers and work mode
  public func launchSessions() async {
    guard let repo = selectedRepository, isValid else { return }

    isLaunching = true
    launchError = nil
    claudeProgress = .idle
    codexProgress = .idle

    let prompt = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let repoPath = repo.path

    switch workMode {
    case .local:
      await launchLocalSessions(prompt: prompt, repoPath: repoPath)
    case .worktree:
      autoGenerateBranchNames()
      let providers = selectedProviders
      if providers.count > 1 {
        await launchBothProviders(prompt: prompt, repoPath: repoPath)
      } else if let provider = providers.first {
        switch provider {
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
      }
    }

    isLaunching = false
    onLaunchCompleted?()
    reset()
  }

  /// Fully resets all form state for a fresh start
  public func reset() {
    sharedPrompt = ""
    claudeBranchName = ""
    codexBranchName = ""
    singleBranchName = ""
    baseBranch = nil
    selectedRepository = nil
    availableBranches = []
    currentBranchName = ""
    workMode = .local
    isClaudeSelected = false
    isCodexSelected = false
    claudeProgress = .idle
    codexProgress = .idle
    launchError = nil
  }

  // MARK: - Private

  /// Starts sessions directly in repo directory without worktree creation
  private func launchLocalSessions(prompt: String, repoPath: String) async {
    let providers = selectedProviders

    for provider in providers {
      let viewModel = provider == .claude ? claudeViewModel : codexViewModel
      viewModel.addRepository(at: repoPath)
    }

    try? await Task.sleep(for: .milliseconds(300))

    let worktree = WorktreeBranch(
      name: currentBranchName.isEmpty ? "main" : currentBranchName,
      path: repoPath,
      isWorktree: false
    )

    if providers.contains(.claude) {
      claudeViewModel.refresh()
      try? await Task.sleep(for: .milliseconds(300))
      claudeViewModel.startNewSessionInHub(worktree, initialPrompt: prompt)
    }

    if providers.contains(.codex) {
      try? await Task.sleep(for: .milliseconds(500))
      codexViewModel.refresh()
      try? await Task.sleep(for: .milliseconds(300))
      codexViewModel.startNewSessionInHub(worktree, initialPrompt: prompt)
    }

    claudeViewModel.refresh()
    codexViewModel.refresh()
  }

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
