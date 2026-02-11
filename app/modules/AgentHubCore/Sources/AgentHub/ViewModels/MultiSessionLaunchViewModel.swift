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

// MARK: - ClaudeMode

public enum ClaudeMode: CaseIterable, Sendable {
  case disabled
  case enabled
  case enabledDangerously

  var next: ClaudeMode {
    switch self {
    case .disabled: return .enabled
    case .enabled: return .enabledDangerously
    case .enabledDangerously: return .disabled
    }
  }

  var isSelected: Bool { self != .disabled }

  var dangerouslySkipPermissions: Bool { self == .enabledDangerously }

  var label: String {
    switch self {
    case .disabled, .enabled: return "Claude"
    case .enabledDangerously: return "Claude Dangerously"
    }
  }
}

// MARK: - AttachedFile

public struct AttachedFile: Identifiable, Equatable {
  public let id = UUID()
  public let url: URL
  public let isTemporary: Bool

  public var displayName: String { url.lastPathComponent }

  public var icon: String {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "png", "jpg", "jpeg", "gif", "tiff", "webp", "heic": return "photo"
    case "pdf": return "doc.richtext"
    case "txt", "md", "swift", "py", "js", "ts": return "doc.text"
    default: return "doc"
    }
  }

  public var quotedPath: String {
    let path = url.path
    return path.contains(" ") ? "\"\(path)\"" : path
  }
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
  public var claudeMode: ClaudeMode = .disabled
  public var isCodexSelected: Bool = false
  public var sharedPrompt: String = ""
  public var attachedFiles: [AttachedFile] = []
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

  public var isClaudeSelected: Bool { claudeMode.isSelected }

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
    let hasRepo = selectedRepository != nil
    return hasRepo && hasAnyProviderSelected
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

  // MARK: - Attachments

  public func addAttachedFile(_ url: URL, isTemporary: Bool = false) {
    guard !attachedFiles.contains(where: { $0.url == url }) else { return }
    attachedFiles.append(AttachedFile(url: url, isTemporary: isTemporary))
  }

  public func removeAttachedFile(_ file: AttachedFile) {
    if file.isTemporary {
      try? FileManager.default.removeItem(at: file.url)
    }
    attachedFiles.removeAll { $0.id == file.id }
  }

  // MARK: - Actions

  /// Opens an NSOpenPanel to select a repository directory.
  /// Uses asyncAfter to schedule NSOpenPanel creation on a future run loop iteration,
  /// avoiding HIRunLoopSemaphore deadlock that occurs during GCD dispatch queue drain.
  public func selectRepository() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      MainActor.assumeIsolated {
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
          self.selectedRepository = SelectedRepository(
            path: path,
            name: name,
            worktrees: [],
            isExpanded: true
          )
          Task {
            await self.loadBranches()
          }
        }
      }
    }
  }

  /// Loads local branches and current branch for the selected repository.
  /// Uses a single `git branch` call to get both, reducing process spawns from 3 to 1-2.
  public func loadBranches() async {
    guard let repo = selectedRepository else { return }
    isLoadingBranches = true
    isLoadingCurrentBranch = true

    do {
      let result = try await worktreeService.getLocalBranchesWithCurrent(at: repo.path)
      availableBranches = result.branches
      currentBranchName = result.currentBranchName
      if let first = availableBranches.first {
        baseBranch = first
      }
    } catch {
      availableBranches = []
      currentBranchName = ""
    }

    isLoadingBranches = false
    isLoadingCurrentBranch = false
  }

  /// Auto-generates branch names from prompt/attachment context + short UUID suffix.
  /// Falls back to "session" when no context text exists.
  public func autoGenerateBranchNames() {
    let promptSeed = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachmentSeed = attachedFiles
      .prefix(3)
      .map { $0.url.deletingPathExtension().lastPathComponent }
      .joined(separator: "-")
    let rawSeed = !promptSeed.isEmpty ? promptSeed : attachmentSeed

    // Take first few words from available context, sanitize, and add short UUID.
    let words = rawSeed.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
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

    let trimmedPrompt = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachmentPaths = attachedFiles.map { $0.quotedPath }.joined(separator: " ")
    let initialPrompt: String? = {
      guard !trimmedPrompt.isEmpty else { return nil }
      if attachmentPaths.isEmpty {
        return trimmedPrompt
      }
      return "\(trimmedPrompt) \(attachmentPaths)"
    }()
    let initialInputText: String? =
      trimmedPrompt.isEmpty && !attachmentPaths.isEmpty ? "\(attachmentPaths) " : nil
    let repoPath = repo.path

    switch workMode {
    case .local:
      await launchLocalSessions(initialPrompt: initialPrompt, initialInputText: initialInputText, repoPath: repoPath)
    case .worktree:
      autoGenerateBranchNames()
      let providers = selectedProviders
      if providers.count > 1 {
        await launchBothProviders(initialPrompt: initialPrompt, initialInputText: initialInputText, repoPath: repoPath)
      } else if let provider = providers.first {
        switch provider {
        case .claude:
          await launchSingleProvider(
            initialPrompt: initialPrompt,
            initialInputText: initialInputText,
            repoPath: repoPath,
            branchName: singleBranchName,
            viewModel: claudeViewModel,
            dangerouslySkipPermissions: claudeMode.dangerouslySkipPermissions,
            progressSetter: { self.claudeProgress = $0 }
          )
        case .codex:
          await launchSingleProvider(
            initialPrompt: initialPrompt,
            initialInputText: initialInputText,
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
    for file in attachedFiles where file.isTemporary {
      try? FileManager.default.removeItem(at: file.url)
    }
    attachedFiles = []
    sharedPrompt = ""
    claudeBranchName = ""
    codexBranchName = ""
    singleBranchName = ""
    baseBranch = nil
    selectedRepository = nil
    availableBranches = []
    currentBranchName = ""
    workMode = .local
    claudeMode = .disabled
    isCodexSelected = false
    claudeProgress = .idle
    codexProgress = .idle
    launchError = nil
  }

  // MARK: - Private

  /// Starts sessions directly in repo directory without worktree creation
  private func launchLocalSessions(initialPrompt: String?, initialInputText: String?, repoPath: String) async {
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
      claudeViewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText,
        dangerouslySkipPermissions: claudeMode.dangerouslySkipPermissions
      )
    }

    if providers.contains(.codex) {
      try? await Task.sleep(for: .milliseconds(500))
      codexViewModel.refresh()
      try? await Task.sleep(for: .milliseconds(300))
      codexViewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText
      )
    }

    claudeViewModel.refresh()
    codexViewModel.refresh()
  }

  private func launchBothProviders(initialPrompt: String?, initialInputText: String?, repoPath: String) async {
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
      claudeViewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText,
        dangerouslySkipPermissions: claudeMode.dangerouslySkipPermissions
      )
    }

    try? await Task.sleep(for: .milliseconds(800))

    if let path = codexWorktreePath {
      let worktree = WorktreeBranch(name: codexBranchName, path: path, isWorktree: true)
      codexViewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText
      )
    }

    claudeViewModel.refresh()
    codexViewModel.refresh()
  }

  private func launchSingleProvider(
    initialPrompt: String?,
    initialInputText: String?,
    repoPath: String,
    branchName: String,
    viewModel: CLISessionsViewModel,
    dangerouslySkipPermissions: Bool = false,
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
    viewModel.startNewSessionInHub(
      worktree,
      initialPrompt: initialPrompt,
      initialInputText: initialInputText,
      dangerouslySkipPermissions: dangerouslySkipPermissions
    )
    viewModel.refresh()
  }
}
