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
  private static let aiWorktreeLogPrefix = "[AIWORKTREE]"

  private struct ActiveWorktreeOperation {
    let id: WorktreeCreationOperationID
    let providerLabel: String
    let branchName: String
    let directoryName: String
    let repoPath: String
    let startedAt: Date
  }

  // MARK: - Dependencies

  private let claudeViewModel: CLISessionsViewModel
  private let codexViewModel: CLISessionsViewModel
  private let worktreeService: GitWorktreeService
  private let intelligenceViewModel: IntelligenceViewModel?
  private let worktreeBranchNamingService: (any WorktreeBranchNamingServiceProtocol)?
  private let worktreeSuccessSoundService: (any WorktreeSuccessSoundServiceProtocol)?
  private var playedWorktreeSuccessPaths: Set<String> = []
  private var activeLaunchTask: Task<Void, Never>?
  private var activeWorktreeOperations: [WorktreeCreationOperationID: ActiveWorktreeOperation] = [:]

  // MARK: - Form State

  public var launchMode: LaunchMode = .manual
  public var workMode: WorkMode = .local
  public var claudeMode: ClaudeMode = .disabled
  public var claudeUseWorktree: Bool = false
  public var claudeWorktreeName: String = ""
  public var isCodexSelected: Bool = false
  public var isPlanModeEnabled: Bool = false
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
  public var branchNamingProgress: WorktreeBranchNamingProgress = .idle
  public var branchNamingStartedAt: Date?
  public var branchNamingCompletedAt: Date?
  public var launchError: String?
  public var lastLaunchEndedByCancellation: Bool = false

  // MARK: - Smart Mode State

  public var smartPhase: SmartPhase = .idle
  public var smartProvider: SmartProvider = .claude
  public var smartPlanText: String = ""
  public var smartOrchestrationPlan: OrchestrationPlan?

  // MARK: - Callbacks

  public var onLaunchCompleted: (() -> Void)?

  // MARK: - Computed

  public var isClaudeSelected: Bool { claudeMode.isSelected }

  /// Returns the --worktree name option when Claude is enabled and worktree mode is on.
  /// nil = no --worktree flag; "" = auto-generated name; non-empty = named worktree
  public var claudeWorktreeOption: String? {
    guard claudeMode.isSelected && claudeUseWorktree else { return nil }
    return claudeWorktreeName
  }

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
    intelligenceViewModel: IntelligenceViewModel? = nil,
    worktreeBranchNamingService: (any WorktreeBranchNamingServiceProtocol)? = nil,
    worktreeSuccessSoundService: (any WorktreeSuccessSoundServiceProtocol)? = nil
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
    self.worktreeService = worktreeService
    self.intelligenceViewModel = intelligenceViewModel
    self.worktreeBranchNamingService = worktreeBranchNamingService
    self.worktreeSuccessSoundService = worktreeSuccessSoundService
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
  /// Schedules presentation on the run loop to avoid AppKit's HIRunLoopSemaphore
  /// wait during main-dispatch-queue draining.
  public func selectRepository() {
    NativeOpenPanelPresenter.present { panel in
      panel.title = "Select Repository"
      panel.message = "Choose a git repository"
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = false
    } onSelection: { [weak self] url in
      guard let self else { return }
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

  /// Clears the currently selected repository and related branch state.
  public func clearSelectedRepository() {
    selectedRepository = nil
    availableBranches = []
    currentBranchName = ""
    baseBranch = nil
    isLoadingBranches = false
    isLoadingCurrentBranch = false
    resetBranchNamingProgress()
  }

  /// Preselects a repository already tracked by either provider.
  /// Returns true when a matching repository was found and selected.
  @discardableResult
  public func preselectRepository(path: String) async -> Bool {
    let combined = claudeViewModel.selectedRepositories + codexViewModel.selectedRepositories
    guard let repository = combined.last(where: { $0.path == path }) else {
      return false
    }

    selectedRepository = repository
    await loadBranches()
    return true
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

  /// Directory name for a given branch name in the selected repository
  public func directoryName(for branchName: String) -> String {
    guard let repo = selectedRepository else { return branchName }
    return GitWorktreeService.worktreeDirectoryName(for: branchName, repoName: repo.name)
  }

  /// Creates worktrees and starts sessions based on the selected providers and work/launch mode
  public func launchSessions() async {
    defer { activeLaunchTask = nil }
    guard isValid else { return }
    lastLaunchEndedByCancellation = false

    do {
      switch launchMode {
      case .manual:
        try await launchManualMode()
      case .smart:
        try await startSmartPlanning()
      }
    } catch is CancellationError {
      handleLaunchCancellation()
    } catch {
      launchError = error.localizedDescription
      isLaunching = false
    }
  }

  public func beginLaunch() {
    guard activeLaunchTask == nil, isValid else { return }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.launchSessions()
    }
    activeLaunchTask = task
  }

  public func beginApprovedSmartLaunch() {
    guard activeLaunchTask == nil else { return }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.approveSmartPlan()
    }
    activeLaunchTask = task
  }

  public func cancelLaunch() {
    guard isLaunching || smartPhase == .planning || smartPhase == .launching || activeLaunchTask != nil else { return }
    AppLogger.intelligence.info("\(Self.aiWorktreeLogPrefix, privacy: .public) Launcher cancellation requested by user")
    intelligenceViewModel?.cancelRequest()
    let operationIDs = Array(activeWorktreeOperations.keys)
    let namingService = worktreeBranchNamingService
    Task {
      if let namingService {
        await namingService.cancelActiveRequest()
      }
      for operationID in operationIDs {
        await worktreeService.cancelWorktreeCreation(operationID)
      }
    }
    activeLaunchTask?.cancel()
  }

  /// Backward-compatible wrapper for existing call sites.
  public func cancelSmartLaunch() {
    cancelLaunch()
  }

  // MARK: - Manual Mode

  private func launchManualMode() async throws {
    guard let repo = selectedRepository else { return }
    let workModeName = workMode.rawValue
    let providerNames = selectedProviders.map(\.rawValue).joined(separator: ",")
    let isUsingClaudeLocalWorktree = claudeWorktreeOption != nil

    AppLogger.intelligence.info(
      "\(Self.aiWorktreeLogPrefix, privacy: .public) Start Session launch requested repo=\(repo.name, privacy: .public) workMode=\(workModeName, privacy: .public) providers=\(providerNames, privacy: .public) claudeLocalWorktree=\(isUsingClaudeLocalWorktree)"
    )

    isLaunching = true
    launchError = nil
    lastLaunchEndedByCancellation = false
    playedWorktreeSuccessPaths.removeAll()
    applyWorktreeProgress(.idle, to: \.claudeProgress)
    applyWorktreeProgress(.idle, to: \.codexProgress)
    resetBranchNamingProgress()

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
      if claudeWorktreeOption != nil {
        AppLogger.intelligence.info(
          "\(Self.aiWorktreeLogPrefix, privacy: .public) Local mode is using Claude's --worktree flow; launcher AI worktree naming does not run in this path"
        )
      } else {
        AppLogger.intelligence.info(
          "\(Self.aiWorktreeLogPrefix, privacy: .public) Skipping AI worktree naming because the Start Session launch is in local mode"
        )
      }
      try await launchLocalSessions(initialPrompt: initialPrompt, initialInputText: initialInputText, repoPath: repoPath)
    case .worktree:
      let providers = selectedProviders
      AppLogger.intelligence.info(
        "\(Self.aiWorktreeLogPrefix, privacy: .public) Entering launcher worktree naming flow for providers=\(providers.map(\.rawValue).joined(separator: ","), privacy: .public)"
      )
      let namingResult = try await resolveGeneratedBranchNames(
        for: repo,
        launchContext: .manualWorktree,
        promptText: trimmedPrompt,
        providerKinds: providers
      )
      applyResolvedBranchNames(namingResult)
      guard validateResolvedBranchNames(for: providers) else {
        AppLogger.intelligence.error(
          "\(Self.aiWorktreeLogPrefix, privacy: .public) Worktree naming completed without usable branch names"
        )
        applyBranchNamingProgress(.failed(message: "AgentHub could not resolve a usable branch name"))
        launchError = "Failed to resolve worktree branch names."
        isLaunching = false
        return
      }

      if providers.count > 1 {
        try await launchBothProviders(initialPrompt: initialPrompt, initialInputText: initialInputText, repoPath: repoPath)
      } else if let provider = providers.first {
        switch provider {
        case .claude:
          try await launchSingleProvider(
            initialPrompt: initialPrompt,
            initialInputText: initialInputText,
            repoPath: repoPath,
            branchName: singleBranchName,
            viewModel: claudeViewModel,
            providerLabel: SessionProviderKind.claude.rawValue,
            dangerouslySkipPermissions: claudeMode.dangerouslySkipPermissions,
            permissionModePlan: isPlanModeEnabled,
            progressKeyPath: \.claudeProgress
          )
        case .codex:
          try await launchSingleProvider(
            initialPrompt: initialPrompt,
            initialInputText: initialInputText,
            repoPath: repoPath,
            branchName: singleBranchName,
            viewModel: codexViewModel,
            providerLabel: SessionProviderKind.codex.rawValue,
            permissionModePlan: isPlanModeEnabled,
            progressKeyPath: \.codexProgress
          )
        }
      }
    }

    try Task.checkCancellation()
    isLaunching = false
    onLaunchCompleted?()
    reset()
  }

  // MARK: - Smart Mode

  /// Phase 1: Send prompt to SDK with plan permission mode and stream a plan.
  private func startSmartPlanning() async throws {
    guard let repo = selectedRepository,
          let intelligence = intelligenceViewModel else { return }

    let trimmedPrompt = sharedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else { return }

    AppLogger.intelligence.info("Smart planning: starting for repo \(repo.path)")

    smartPhase = .planning
    isLaunching = true
    launchError = nil
    lastLaunchEndedByCancellation = false

    // Build prompt with attachment paths if any
    let attachmentPaths = attachedFiles.map { $0.quotedPath }.joined(separator: " ")
    let fullPrompt = attachmentPaths.isEmpty ? trimmedPrompt : "\(trimmedPrompt) \(attachmentPaths)"

    // Generate plan via SDK (plan mode, no execution)
    intelligence.generatePlan(prompt: fullPrompt, workingDirectory: repo.path)

    // Poll for completion
    while intelligence.isLoading {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(200))
    }

    try Task.checkCancellation()

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
    defer { activeLaunchTask = nil }
    guard let repo = selectedRepository else { return }

    do {
      AppLogger.intelligence.info("Smart plan: approved")

      smartPhase = .launching
      isLaunching = true
      launchError = nil
      lastLaunchEndedByCancellation = false
      playedWorktreeSuccessPaths.removeAll()
      applyWorktreeProgress(.idle, to: \.claudeProgress)
      applyWorktreeProgress(.idle, to: \.codexProgress)
      resetBranchNamingProgress()

      let viewModel = smartProvider == .claude ? claudeViewModel : codexViewModel
      let repoPath = repo.path
      let dangerously = smartProvider == .claude ? claudeMode.dangerouslySkipPermissions : false

      viewModel.addRepository(at: repoPath)
      try await Task.sleep(for: .milliseconds(300))
      try Task.checkCancellation()

      if let plan = smartOrchestrationPlan, !plan.sessions.isEmpty {
        // Multi-session launch from parsed orchestration plan
        try await launchOrchestrationSessions(
          plan: plan,
          repoPath: repoPath,
          viewModel: viewModel,
          dangerouslySkipPermissions: dangerously,
          permissionModePlan: isPlanModeEnabled
        )
      } else {
        // Fallback: single session with the full plan text (not the original prompt)
        try await launchFallbackSession(
          repoPath: repoPath,
          repoName: repo.name,
          viewModel: viewModel,
          dangerouslySkipPermissions: dangerously,
          permissionModePlan: isPlanModeEnabled
        )
      }
    } catch is CancellationError {
      handleLaunchCancellation()
    } catch {
      launchError = error.localizedDescription
      isLaunching = false
      smartPhase = .planReady
    }
  }

  /// Launches one worktree + session per orchestration session.
  private func launchOrchestrationSessions(
    plan: OrchestrationPlan,
    repoPath: String,
    viewModel: CLISessionsViewModel,
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool = false
  ) async throws {
    var errors: [String] = []

    for (index, session) in plan.sessions.enumerated() {
      try Task.checkCancellation()
      AppLogger.intelligence.info(
        "Smart plan: creating session \(index + 1)/\(plan.sessions.count) — \(session.branchName)"
      )

      do {
        let dirName = GitWorktreeService.worktreeDirectoryName(
          for: session.branchName, repoName: URL(fileURLWithPath: repoPath).lastPathComponent
        )
        let worktreePath = try await createWorktreeForLaunch(
          providerLabel: smartProvider.rawValue,
          repoPath: repoPath,
          branchName: session.branchName,
          directoryName: dirName,
          startPoint: baseBranch?.displayName,
          progressKeyPath: \.claudeProgress
        )

        viewModel.refresh()
        try await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()

        let worktree = WorktreeBranch(name: session.branchName, path: worktreePath, isWorktree: true)
        viewModel.startNewSessionInHub(
          worktree,
          initialPrompt: session.prompt,
          dangerouslySkipPermissions: dangerouslySkipPermissions,
          permissionModePlan: permissionModePlan
        )
        viewModel.refresh()

        AppLogger.intelligence.info("Smart plan: session launched at \(worktreePath)")

        // Delay between launches to prevent macOS race conditions
        if index < plan.sessions.count - 1 {
          try await Task.sleep(for: .milliseconds(800))
        }
        try Task.checkCancellation()
      } catch is CancellationError {
        throw CancellationError()
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
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool = false
  ) async throws {
    // Use the full plan text as the prompt, not the original user message
    let initialPrompt = smartPlanText.isEmpty ? sharedPrompt : smartPlanText
    guard let repository = selectedRepository else { return }

    let namingResult = try await resolveGeneratedBranchNames(
      for: repository,
      launchContext: .smartFallback,
      promptText: initialPrompt,
      providerKinds: [smartProvider == .claude ? .claude : .codex]
    )

    guard let branchName = namingResult.single else {
      applyBranchNamingProgress(.failed(message: "AgentHub could not resolve a fallback branch name"))
      launchError = "Failed to resolve a worktree branch name."
      smartPhase = .planReady
      isLaunching = false
      return
    }

    do {
      let dirName = GitWorktreeService.worktreeDirectoryName(for: branchName, repoName: repoName)
      let worktreePath = try await createWorktreeForLaunch(
        providerLabel: smartProvider.rawValue,
        repoPath: repoPath,
        branchName: branchName,
        directoryName: dirName,
        startPoint: baseBranch?.displayName,
        progressKeyPath: \.claudeProgress
      )

      viewModel.refresh()
      try await Task.sleep(for: .milliseconds(500))
      try Task.checkCancellation()

      let worktree = WorktreeBranch(name: branchName, path: worktreePath, isWorktree: true)
      viewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        dangerouslySkipPermissions: dangerouslySkipPermissions,
        permissionModePlan: permissionModePlan
      )
      viewModel.refresh()

      AppLogger.intelligence.info("Smart plan: fallback session launched at \(worktreePath)")
      isLaunching = false
      onLaunchCompleted?()
      reset()
    } catch is CancellationError {
      throw CancellationError()
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
    resetBranchNamingProgress()
  }

  /// Fully resets all form state for a fresh start
  public func reset() {
    activeLaunchTask?.cancel()
    activeLaunchTask = nil
    activeWorktreeOperations.removeAll()
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
    claudeUseWorktree = false
    claudeWorktreeName = ""
    isCodexSelected = false
    isPlanModeEnabled = false
    playedWorktreeSuccessPaths.removeAll()
    claudeProgress = .idle
    codexProgress = .idle
    resetBranchNamingProgress()
    launchError = nil
    lastLaunchEndedByCancellation = false
    smartPhase = .idle
    smartProvider = .claude
    smartPlanText = ""
    smartOrchestrationPlan = nil
  }

  // MARK: - Private

  /// Starts sessions directly in repo directory without worktree creation
  private func launchLocalSessions(initialPrompt: String?, initialInputText: String?, repoPath: String) async throws {
    let providers = selectedProviders

    for provider in providers {
      let viewModel = provider == .claude ? claudeViewModel : codexViewModel
      viewModel.addRepository(at: repoPath)
    }

    try await Task.sleep(for: .milliseconds(300))
    try Task.checkCancellation()

    let worktreeBranchName: String = {
      if let name = claudeWorktreeOption, !name.isEmpty { return name }
      return currentBranchName.isEmpty ? "main" : currentBranchName
    }()
    let worktree = WorktreeBranch(
      name: worktreeBranchName,
      path: repoPath,
      isWorktree: claudeWorktreeOption != nil
    )

    if providers.contains(.claude) {
      claudeViewModel.refresh()
      try await Task.sleep(for: .milliseconds(300))
      try Task.checkCancellation()
      claudeViewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText,
        dangerouslySkipPermissions: claudeMode.dangerouslySkipPermissions,
        permissionModePlan: isPlanModeEnabled,
        worktreeName: claudeWorktreeOption
      )
    }

    if providers.contains(.codex) {
      try await Task.sleep(for: .milliseconds(500))
      try Task.checkCancellation()
      codexViewModel.refresh()
      try await Task.sleep(for: .milliseconds(300))
      try Task.checkCancellation()
      codexViewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText,
        permissionModePlan: isPlanModeEnabled
      )
    }

    claudeViewModel.refresh()
    codexViewModel.refresh()
  }

  private func launchBothProviders(initialPrompt: String?, initialInputText: String?, repoPath: String) async throws {
    // Ensure the repository is added to both providers
    claudeViewModel.addRepository(at: repoPath)
    codexViewModel.addRepository(at: repoPath)
    try await Task.sleep(for: .milliseconds(300))
    try Task.checkCancellation()

    // 1. Create Claude worktree
    var claudeWorktreePath: String?
    do {
      let dirName = directoryName(for: claudeBranchName)
      claudeWorktreePath = try await createWorktreeForLaunch(
        providerLabel: SessionProviderKind.claude.rawValue,
        repoPath: repoPath,
        branchName: claudeBranchName,
        directoryName: dirName,
        startPoint: baseBranch?.displayName,
        progressKeyPath: \.claudeProgress
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      applyWorktreeProgress(.failed(error: error.localizedDescription), to: \.claudeProgress)
      launchError = "Claude worktree: \(error.localizedDescription)"
    }

    try Task.checkCancellation()

    // 2. Create Codex worktree
    var codexWorktreePath: String?
    do {
      let dirName = directoryName(for: codexBranchName)
      codexWorktreePath = try await createWorktreeForLaunch(
        providerLabel: SessionProviderKind.codex.rawValue,
        repoPath: repoPath,
        branchName: codexBranchName,
        directoryName: dirName,
        startPoint: baseBranch?.displayName,
        progressKeyPath: \.codexProgress
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      applyWorktreeProgress(.failed(error: error.localizedDescription), to: \.codexProgress)
      let msg = "Codex worktree: \(error.localizedDescription)"
      launchError = launchError != nil ? "\(launchError!)\n\(msg)" : msg
    }

    guard claudeWorktreePath != nil || codexWorktreePath != nil else { return }

    // 3. Refresh and start sessions
    claudeViewModel.refresh()
    codexViewModel.refresh()
    try await Task.sleep(for: .milliseconds(500))
    try Task.checkCancellation()

    if let path = claudeWorktreePath {
      let worktree = WorktreeBranch(name: claudeBranchName, path: path, isWorktree: true)
      claudeViewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText,
        dangerouslySkipPermissions: claudeMode.dangerouslySkipPermissions,
        permissionModePlan: isPlanModeEnabled
      )
    }

    try await Task.sleep(for: .milliseconds(800))
    try Task.checkCancellation()

    if let path = codexWorktreePath {
      let worktree = WorktreeBranch(name: codexBranchName, path: path, isWorktree: true)
      codexViewModel.startNewSessionInHub(
        worktree,
        initialPrompt: initialPrompt,
        initialInputText: initialInputText,
        permissionModePlan: isPlanModeEnabled
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
    providerLabel: String,
    dangerouslySkipPermissions: Bool = false,
    permissionModePlan: Bool = false,
    progressKeyPath: ReferenceWritableKeyPath<MultiSessionLaunchViewModel, WorktreeCreationProgress>
  ) async throws {
    viewModel.addRepository(at: repoPath)
    try await Task.sleep(for: .milliseconds(300))
    try Task.checkCancellation()

    var worktreePath: String?
    do {
      let dirName = directoryName(for: branchName)
      worktreePath = try await createWorktreeForLaunch(
        providerLabel: providerLabel,
        repoPath: repoPath,
        branchName: branchName,
        directoryName: dirName,
        startPoint: baseBranch?.displayName,
        progressKeyPath: progressKeyPath
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      applyWorktreeProgress(.failed(error: error.localizedDescription), to: progressKeyPath)
      launchError = error.localizedDescription
      return
    }

    guard let path = worktreePath else { return }

    viewModel.refresh()
    try await Task.sleep(for: .milliseconds(500))
    try Task.checkCancellation()

    let worktree = WorktreeBranch(name: branchName, path: path, isWorktree: true)
    viewModel.startNewSessionInHub(
      worktree,
      initialPrompt: initialPrompt,
      initialInputText: initialInputText,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan
    )
    viewModel.refresh()
  }

  func resolveGeneratedBranchNames(
    for repository: SelectedRepository,
    launchContext: WorktreeBranchNamingLaunchContext,
    promptText: String,
    providerKinds: [SessionProviderKind]
  ) async throws -> WorktreeBranchNamingResult {
    let attachmentNames = attachmentBasenames
    let providerNames = providerKinds.map(\.rawValue).joined(separator: ",")
    let baseBranchName = baseBranch?.displayName ?? "HEAD"
    let request = WorktreeBranchNamingRequest(
      repoName: repository.name,
      repoPath: repository.path,
      baseBranchName: baseBranch?.displayName,
      launchContext: launchContext,
      promptText: promptText,
      attachmentBasenames: attachmentNames,
      providerKinds: providerKinds
    )

    AppLogger.intelligence.info(
      "\(Self.aiWorktreeLogPrefix, privacy: .public) Built naming request context=\(launchContext.rawValue, privacy: .public) repo=\(repository.name, privacy: .public) base=\(baseBranchName, privacy: .public) providers=\(providerNames, privacy: .public) promptLength=\(promptText.count) attachments=\(attachmentNames.joined(separator: ","), privacy: .public)"
    )
    let namingStartedAt = Date()
    AppLogger.intelligence.info(
      "\(Self.aiWorktreeLogPrefix, privacy: .public) Branch naming started context=\(launchContext.rawValue, privacy: .public) repo=\(repository.name, privacy: .public) providers=\(providerNames, privacy: .public)"
    )

    if let worktreeBranchNamingService {
      branchNamingStartedAt = Date()
      branchNamingCompletedAt = nil
      branchNamingProgress = .preparingContext(
        message: request.hasMeaningfulContext
          ? "Preparing branch naming context"
          : "Preparing repository context"
      )
      do {
        let result = try await worktreeBranchNamingService.resolveBranchNames(for: request) { [weak self] progress in
          self?.applyBranchNamingProgress(progress)
        }
        finalizeBranchNamingProgress(with: result)
        AppLogger.intelligence.info(
          "\(Self.aiWorktreeLogPrefix, privacy: .public) Branch naming completed source=\(result.source.rawValue, privacy: .public) elapsed=\(Self.formattedElapsed(since: namingStartedAt), privacy: .public)"
        )
        AppLogger.intelligence.info(
          "\(Self.aiWorktreeLogPrefix, privacy: .public) Resolved worktree names via \(result.source.rawValue, privacy: .public)"
        )
        return result
      } catch is CancellationError {
        applyBranchNamingProgress(.cancelled(message: "Branch naming cancelled"))
        AppLogger.intelligence.info(
          "\(Self.aiWorktreeLogPrefix, privacy: .public) Branch naming cancelled elapsed=\(Self.formattedElapsed(since: namingStartedAt), privacy: .public)"
        )
        throw CancellationError()
      }
    }

    branchNamingStartedAt = Date()
    branchNamingCompletedAt = nil
    branchNamingProgress = .preparingContext(message: "Preparing fallback branch name")
    let fallback = ClaudeWorktreeBranchNamingService.deterministicFallback(for: request)
    finalizeBranchNamingProgress(with: fallback)
    AppLogger.intelligence.info(
      "\(Self.aiWorktreeLogPrefix, privacy: .public) Branch naming completed source=\(fallback.source.rawValue, privacy: .public) elapsed=\(Self.formattedElapsed(since: namingStartedAt), privacy: .public)"
    )
    AppLogger.intelligence.info(
      "\(Self.aiWorktreeLogPrefix, privacy: .public) No naming service was available; resolved worktree names via deterministic fallback"
    )
    return fallback
  }

  private var attachmentBasenames: [String] {
    attachedFiles.prefix(3).map { $0.url.deletingPathExtension().lastPathComponent }
  }

  private func applyResolvedBranchNames(_ result: WorktreeBranchNamingResult) {
    singleBranchName = result.single ?? ""
    claudeBranchName = result.claude ?? ""
    codexBranchName = result.codex ?? ""
    let resolvedSingle = singleBranchName
    let resolvedClaude = claudeBranchName
    let resolvedCodex = codexBranchName
    AppLogger.intelligence.info(
      "\(Self.aiWorktreeLogPrefix, privacy: .public) Applied resolved branch names single=\(resolvedSingle, privacy: .public) claude=\(resolvedClaude, privacy: .public) codex=\(resolvedCodex, privacy: .public)"
    )
  }

  private func validateResolvedBranchNames(for providers: [SessionProviderKind]) -> Bool {
    if providers.count > 1 {
      return (!claudeBranchName.isEmpty || !codexBranchName.isEmpty)
        && (!providers.contains(.claude) || !claudeBranchName.isEmpty)
        && (!providers.contains(.codex) || !codexBranchName.isEmpty)
    }
    return !singleBranchName.isEmpty
  }

  private func applyBranchNamingProgress(_ progress: WorktreeBranchNamingProgress) {
    if branchNamingStartedAt == nil {
      branchNamingStartedAt = Date()
    }

    branchNamingProgress = progress

    if progress.isFinished {
      branchNamingCompletedAt = Date()
    } else {
      branchNamingCompletedAt = nil
    }
  }

  private func finalizeBranchNamingProgress(with result: WorktreeBranchNamingResult) {
    let resolvedBranchNames = [result.single, result.claude, result.codex].compactMap { $0 }
    if case .completed(_, let source, let branchNames) = branchNamingProgress,
       source == result.source,
       branchNames == resolvedBranchNames {
      if branchNamingCompletedAt == nil {
        branchNamingCompletedAt = Date()
      }
      return
    }

    let finalProgress = WorktreeBranchNamingProgress.completed(
      message: result.source == .ai
        ? "Branch name ready"
        : "Fallback branch name ready",
      source: result.source,
      branchNames: resolvedBranchNames
    )

    applyBranchNamingProgress(finalProgress)
  }

  private func resetBranchNamingProgress() {
    branchNamingProgress = .idle
    branchNamingStartedAt = nil
    branchNamingCompletedAt = nil
  }

  private func handleLaunchCancellation() {
    lastLaunchEndedByCancellation = true
    launchError = nil
    isLaunching = false
    activeLaunchTask = nil
    singleBranchName = ""
    claudeBranchName = ""
    codexBranchName = ""
    activeWorktreeOperations.removeAll()

    if branchNamingProgress.isInProgress {
      applyBranchNamingProgress(.cancelled(message: "Branch naming cancelled"))
    }

    if case .preparing = claudeProgress {
      claudeProgress = .cancelled(message: "Worktree creation cancelled")
    } else if case .updatingFiles = claudeProgress {
      claudeProgress = .cancelled(message: "Worktree creation cancelled")
    }

    if case .preparing = codexProgress {
      codexProgress = .cancelled(message: "Worktree creation cancelled")
    } else if case .updatingFiles = codexProgress {
      codexProgress = .cancelled(message: "Worktree creation cancelled")
    }

    switch smartPhase {
    case .planning:
      smartPhase = .idle
    case .launching:
      smartPhase = smartOrchestrationPlan != nil || !smartPlanText.isEmpty ? .planReady : .idle
    case .idle, .planReady:
      break
    }
  }

  private func createWorktreeForLaunch(
    providerLabel: String,
    repoPath: String,
    branchName: String,
    directoryName: String,
    startPoint: String?,
    progressKeyPath: ReferenceWritableKeyPath<MultiSessionLaunchViewModel, WorktreeCreationProgress>
  ) async throws -> String {
    let operationID = WorktreeCreationOperationID()
    let operation = ActiveWorktreeOperation(
      id: operationID,
      providerLabel: providerLabel,
      branchName: branchName,
      directoryName: directoryName,
      repoPath: repoPath,
      startedAt: Date()
    )
    activeWorktreeOperations[operationID] = operation

    AppLogger.intelligence.info(
      "\(Self.aiWorktreeLogPrefix, privacy: .public) Worktree creation started provider=\(providerLabel, privacy: .public) branch=\(branchName, privacy: .public)"
    )

    let progressUpdater: @MainActor (WorktreeCreationProgress) -> Void = { [weak self] progress in
      self?.applyWorktreeProgress(progress, to: progressKeyPath)
    }

    do {
      let path = try await worktreeService.createWorktreeWithNewBranch(
        at: repoPath,
        newBranchName: branchName,
        directoryName: directoryName,
        startPoint: startPoint,
        operationID: operationID
      ) { progress in
        await progressUpdater(progress)
      }
      activeWorktreeOperations.removeValue(forKey: operationID)
      AppLogger.intelligence.info(
        "\(Self.aiWorktreeLogPrefix, privacy: .public) Worktree creation completed provider=\(providerLabel, privacy: .public) branch=\(branchName, privacy: .public) elapsed=\(Self.formattedElapsed(since: operation.startedAt), privacy: .public)"
      )
      return path
    } catch WorktreeCreationError.cancelled {
      activeWorktreeOperations.removeValue(forKey: operationID)
      applyWorktreeProgress(.cancelled(message: "Worktree creation cancelled"), to: progressKeyPath)
      AppLogger.intelligence.info(
        "\(Self.aiWorktreeLogPrefix, privacy: .public) Worktree creation cancelled provider=\(providerLabel, privacy: .public) branch=\(branchName, privacy: .public) elapsed=\(Self.formattedElapsed(since: operation.startedAt), privacy: .public)"
      )
      let cleanup = await worktreeService.cleanupCancelledWorktreeCreation(
        repoPath: operation.repoPath,
        newBranchName: operation.branchName,
        directoryName: operation.directoryName
      )
      AppLogger.intelligence.info(
        "\(Self.aiWorktreeLogPrefix, privacy: .public) Worktree cleanup completed provider=\(providerLabel, privacy: .public) branch=\(branchName, privacy: .public) removedWorktree=\(cleanup.removedWorktree) removedBranch=\(cleanup.removedBranch) notes=\(cleanup.notes.joined(separator: " | "), privacy: .public)"
      )
      throw CancellationError()
    } catch {
      activeWorktreeOperations.removeValue(forKey: operationID)
      AppLogger.intelligence.error(
        "\(Self.aiWorktreeLogPrefix, privacy: .public) Worktree creation failed provider=\(providerLabel, privacy: .public) branch=\(branchName, privacy: .public) elapsed=\(Self.formattedElapsed(since: operation.startedAt), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  private static func formattedElapsed(since startDate: Date) -> String {
    String(format: "%.2fs", Date().timeIntervalSince(startDate))
  }

  private func applyWorktreeProgress(
    _ progress: WorktreeCreationProgress,
    to keyPath: ReferenceWritableKeyPath<MultiSessionLaunchViewModel, WorktreeCreationProgress>
  ) {
    self[keyPath: keyPath] = progress

    guard case .completed(let path) = progress,
          playedWorktreeSuccessPaths.insert(path).inserted else {
      return
    }

    AppLogger.intelligence.info(
      "\(Self.aiWorktreeLogPrefix, privacy: .public) Worktree creation completed path=\(path, privacy: .public); playing success sound"
    )

    guard let worktreeSuccessSoundService else { return }
    Task {
      await worktreeSuccessSoundService.playWorktreeCreatedSound()
    }
  }
}
