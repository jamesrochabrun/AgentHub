//
//  MultiSessionLaunchViewModel.swift
//  AgentHub
//
//  View model for the Session Launcher.
//  Coordinates creating worktrees and starting sessions for Claude, Codex, or both.
//

import AppKit
import Foundation

// MARK: - LaunchMode

public enum LaunchMode: String, CaseIterable, Sendable {
  case manual = "Manual"
  case smart = "Smart"
}

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

// MARK: - SmartPhase

public enum SmartPhase: Equatable {
  case idle
  case planning
  case planReady
  case launching
}

// MARK: - SmartProvider

public enum SmartProvider: String, CaseIterable, Sendable {
  case claude = "Claude"
  case codex = "Codex"
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
  private let intelligenceViewModel: IntelligenceViewModel?

  // MARK: - Form State

  public var launchMode: LaunchMode = .manual
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

  // MARK: - Smart Mode State

  public var smartPhase: SmartPhase = .idle
  public var smartProvider: SmartProvider = .claude
  public var smartPlanText: String = ""
  public var smartOrchestrationPlan: OrchestrationPlan?

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

  public var isSmartModeAvailable: Bool {
    intelligenceViewModel != nil
  }

  public var isSmartInteractive: Bool {
    smartPhase == .planning || smartPhase == .planReady || smartPhase == .launching
  }

  public var isValid: Bool {
    let hasRepo = selectedRepository != nil
    switch launchMode {
    case .manual:
      return hasRepo && hasAnyProviderSelected
    case .smart:
      let hasPrompt = !sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      return hasRepo && hasPrompt
    }
  }

  // MARK: - Init

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel,
    worktreeService: GitWorktreeService = GitWorktreeService(),
    intelligenceViewModel: IntelligenceViewModel? = nil
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.worktreeService = worktreeService
    self.intelligenceViewModel = intelligenceViewModel
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

  /// Creates worktrees and starts sessions based on the selected providers and work/launch mode
  public func launchSessions() async {
    guard isValid else { return }

    switch launchMode {
    case .manual:
      await launchManualMode()
    case .smart:
      await startSmartPlanning()
    }
  }

  /// Cancels an in-progress smart launch and resets state
  public func cancelSmartLaunch() {
    AppLogger.intelligence.info("Smart launch: cancelled by user")
    intelligenceViewModel?.cancelRequest()
    smartPhase = .idle
    isLaunching = false
    launchError = nil
  }

  // MARK: - Manual Mode

  private func launchManualMode() async {
    guard let repo = selectedRepository else { return }

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

  // MARK: - Smart Mode

  /// Phase 1: Send prompt to SDK with plan permission mode and stream a plan.
  private func startSmartPlanning() async {
    guard let repo = selectedRepository,
          let intelligence = intelligenceViewModel else { return }

    let trimmedPrompt = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else { return }

    AppLogger.intelligence.info("Smart planning: starting for repo \(repo.path)")

    smartPhase = .planning
    isLaunching = true
    launchError = nil

    // Build prompt with attachment paths if any
    let attachmentPaths = attachedFiles.map { $0.quotedPath }.joined(separator: " ")
    let fullPrompt = attachmentPaths.isEmpty ? trimmedPrompt : "\(trimmedPrompt) \(attachmentPaths)"

    // Generate plan via SDK (plan mode, no execution)
    intelligence.generatePlan(prompt: fullPrompt, workingDirectory: repo.path)

    // Poll for completion
    while intelligence.isLoading {
      try? await Task.sleep(for: .milliseconds(200))
    }

    // Check for errors
    if let error = intelligence.errorMessage {
      AppLogger.intelligence.error("Smart planning: error — \(error)")
      launchError = error
      smartPhase = .idle
      isLaunching = false
      return
    }

    // Store completed plan text and parsed orchestration plan
    let rawResponse = intelligence.lastResponse
    let lastMessage = intelligence.lastAssistantMessage
    smartOrchestrationPlan = intelligence.parsedOrchestrationPlan
      ?? WorktreeOrchestrationTool.parseFromText(rawResponse)
      ?? WorktreeOrchestrationTool.parseFromText(lastMessage)
      ?? WorktreeOrchestrationTool.parseJSONFromText(rawResponse)
      ?? WorktreeOrchestrationTool.parseJSONFromText(lastMessage)

    // Use only the final assistant message for display (excludes exploration text)
    smartPlanText = WorktreeOrchestrationTool.stripPlanMarkers(lastMessage)

    // Diagnostic logging
    let planSummary = self.smartOrchestrationPlan.map { "\($0.sessions.count) sessions" } ?? "nil"
    AppLogger.intelligence.info("""
      Smart planning diagnostics:
      - rawResponse length: \(rawResponse.count)
      - lastMessage length: \(lastMessage.count)
      - has XML markers (raw): \(WorktreeOrchestrationTool.containsPlanMarkers(rawResponse))
      - has XML markers (last): \(WorktreeOrchestrationTool.containsPlanMarkers(lastMessage))
      - has JSON keys (raw): \(rawResponse.contains("\"modulePath\""))
      - parsedOrchestrationPlan: \(planSummary)
      """)

    if smartOrchestrationPlan == nil && WorktreeOrchestrationTool.containsPlanMarkers(rawResponse) {
      AppLogger.intelligence.error("Plan markers found but parsing failed. Raw response length: \(rawResponse.count)")
      assertionFailure("Orchestration plan markers present but all parsing attempts failed")
    }

    smartPhase = .planReady
    isLaunching = false
    AppLogger.intelligence.info("Smart planning: plan ready (\(self.smartPlanText.count) chars)")
  }

  /// Phase 2: User approved the plan — create worktrees and start sessions.
  /// If a parsed orchestration plan exists, launches one session per task.
  /// Otherwise falls back to a single session using the full plan text.
  public func approveSmartPlan() async {
    guard let repo = selectedRepository else { return }

    AppLogger.intelligence.info("Smart plan: approved")

    smartPhase = .launching
    isLaunching = true
    launchError = nil

    let viewModel = smartProvider == .claude ? claudeViewModel : codexViewModel
    let repoPath = repo.path
    let dangerously = smartProvider == .claude ? claudeMode.dangerouslySkipPermissions : false

    viewModel.addRepository(at: repoPath)
    try? await Task.sleep(for: .milliseconds(300))

    if let plan = smartOrchestrationPlan, !plan.sessions.isEmpty {
      // Multi-session launch from parsed orchestration plan
      await launchOrchestrationSessions(
        plan: plan,
        repoPath: repoPath,
        viewModel: viewModel,
        dangerouslySkipPermissions: dangerously
      )
    } else {
      // Fallback: single session with the full plan text (not the original prompt)
      await launchFallbackSession(
        repoPath: repoPath,
        repoName: repo.name,
        viewModel: viewModel,
        dangerouslySkipPermissions: dangerously
      )
    }
  }

  /// Launches one worktree + session per orchestration session.
  private func launchOrchestrationSessions(
    plan: OrchestrationPlan,
    repoPath: String,
    viewModel: CLISessionsViewModel,
    dangerouslySkipPermissions: Bool
  ) async {
    var errors: [String] = []

    for (index, session) in plan.sessions.enumerated() {
      AppLogger.intelligence.info(
        "Smart plan: creating session \(index + 1)/\(plan.sessions.count) — \(session.branchName)"
      )

      do {
        let dirName = GitWorktreeService.worktreeDirectoryName(
          for: session.branchName, repoName: URL(fileURLWithPath: repoPath).lastPathComponent
        )
        let worktreePath = try await worktreeService.createWorktreeWithNewBranch(
          at: repoPath,
          newBranchName: session.branchName,
          directoryName: dirName,
          startPoint: baseBranch?.displayName
        ) { [weak self] progress in
          Task { @MainActor in
            self?.claudeProgress = progress
          }
        }

        viewModel.refresh()
        try? await Task.sleep(for: .milliseconds(500))

        let worktree = WorktreeBranch(name: session.branchName, path: worktreePath, isWorktree: true)
        viewModel.startNewSessionInHub(
          worktree,
          initialPrompt: session.prompt,
          dangerouslySkipPermissions: dangerouslySkipPermissions
        )
        viewModel.refresh()

        AppLogger.intelligence.info("Smart plan: session launched at \(worktreePath)")

        // Delay between launches to prevent macOS race conditions
        if index < plan.sessions.count - 1 {
          try? await Task.sleep(for: .milliseconds(800))
        }
      } catch {
        let msg = "\(session.branchName): \(error.localizedDescription)"
        AppLogger.intelligence.error("Smart plan: worktree failed — \(msg)")
        errors.append(msg)
      }
    }

    if !errors.isEmpty {
      launchError = "Some sessions failed:\n\(errors.joined(separator: "\n"))"
    }

    isLaunching = false
    onLaunchCompleted?()
    reset()
  }

  /// Fallback: launches a single session with the full plan text as the prompt.
  private func launchFallbackSession(
    repoPath: String,
    repoName: String,
    viewModel: CLISessionsViewModel,
    dangerouslySkipPermissions: Bool
  ) async {
    // Auto-generate branch name from prompt
    let promptSeed = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = promptSeed.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .prefix(4)
      .joined(separator: "-")
    let sanitized = GitWorktreeService.sanitizeBranchName(words)
    let suffix = String(UUID().uuidString.prefix(6)).lowercased()
    let branchName = sanitized.isEmpty ? "smart-\(suffix)" : "\(sanitized)-\(suffix)"

    // Use the full plan text as the prompt, not the original user message
    let initialPrompt = smartPlanText.isEmpty ? sharedPrompt : smartPlanText

    do {
      let dirName = GitWorktreeService.worktreeDirectoryName(for: branchName, repoName: repoName)
      let worktreePath = try await worktreeService.createWorktreeWithNewBranch(
        at: repoPath,
        newBranchName: branchName,
        directoryName: dirName,
        startPoint: baseBranch?.displayName
      ) { [weak self] progress in
        Task { @MainActor in
          self?.claudeProgress = progress
        }
      }

      viewModel.refresh()
      try? await Task.sleep(for: .milliseconds(500))

      let worktree = WorktreeBranch(name: branchName, path: worktreePath, isWorktree: true)
      viewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        dangerouslySkipPermissions: dangerouslySkipPermissions
      )
      viewModel.refresh()

      AppLogger.intelligence.info("Smart plan: fallback session launched at \(worktreePath)")
      isLaunching = false
      onLaunchCompleted?()
      reset()
    } catch {
      AppLogger.intelligence.error("Smart plan: worktree creation failed — \(error.localizedDescription)")
      launchError = "Worktree creation failed: \(error.localizedDescription)"
      smartPhase = .planReady
      isLaunching = false
    }
  }

  /// Phase 2 (reject): User rejected the plan — go back to idle keeping prompt and repo.
  public func rejectSmartPlan() {
    AppLogger.intelligence.info("Smart plan: rejected by user")
    smartPhase = .idle
    smartPlanText = ""
    smartOrchestrationPlan = nil
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
    launchMode = .manual
    workMode = .local
    claudeMode = .disabled
    isCodexSelected = false
    claudeProgress = .idle
    codexProgress = .idle
    launchError = nil
    smartPhase = .idle
    smartProvider = .claude
    smartPlanText = ""
    smartOrchestrationPlan = nil
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
