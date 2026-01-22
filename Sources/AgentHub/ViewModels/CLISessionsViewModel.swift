//
//  CLISessionsViewModel.swift
//  AgentHub
//
//  Created by Assistant on 1/9/26.
//

import Foundation
import Combine
import ClaudeCodeSDK

#if canImport(AppKit)
import AppKit
#endif

// MARK: - CLISessionsViewModel

/// ViewModel for managing and displaying CLI sessions with repository-based filtering
@MainActor
@Observable
public final class CLISessionsViewModel {

  // MARK: - Dependencies

  private let monitorService: CLISessionMonitorService
  private let searchService: GlobalSearchService
  public let claudeClient: (any ClaudeCode)?
  private let worktreeService = GitWorktreeService()

  // MARK: - State

  public private(set) var selectedRepositories: [SelectedRepository] = []
  public private(set) var loadingState: CLILoadingState = .idle
  public private(set) var error: Error?

  // MARK: - Worktree Deletion State

  public private(set) var deletingWorktreePath: String? = nil
  public private(set) var worktreeDeletionError: WorktreeDeletionError? = nil

  public struct WorktreeDeletionError: Identifiable {
    public let id = UUID()
    public let worktree: WorktreeBranch
    public let message: String
  }

  // MARK: - Search State

  public var searchQuery: String = ""
  public private(set) var searchResults: [SessionSearchResult] = []
  public private(set) var isSearching: Bool = false
  public private(set) var hasPerformedSearch: Bool = false
  private var searchTask: Task<Void, Never>?

  /// Whether the search is active (has a query)
  public var isSearchActive: Bool {
    !searchQuery.isEmpty
  }

  // MARK: - Search Filter State

  /// Optional repository path to filter search results
  public var searchFilterPath: String? = nil

  /// The repository name for the filter (derived from path)
  public var searchFilterName: String? {
    searchFilterPath.map { URL(fileURLWithPath: $0).lastPathComponent }
  }

  /// Whether a search filter is active
  public var hasSearchFilter: Bool {
    searchFilterPath != nil
  }

  // MARK: - Auto-Observe State

  /// Session ID pending auto-observe after repo loads
  private var pendingAutoObserveSessionId: String? = nil
  /// Project path for the pending auto-observe session
  private var pendingAutoObserveProjectPath: String? = nil
  /// Worktree path pending auto-observe after terminal opens
  private var pendingAutoObserveWorktreePath: String? = nil
  /// Session IDs that existed before we opened the terminal (to detect new ones)
  private var existingSessionIdsBeforeTerminal: Set<String> = []
  /// Whether the next auto-observed session should show terminal view (from "Start in Hub")
  public var pendingHubSessionWithTerminal: Bool = false
  /// Session IDs that should show terminal view (tracks current state for each row)
  public var sessionsWithTerminalView: Set<String> = []

  /// Maps session IDs to prompts that should be sent to the terminal when it becomes ready.
  ///
  /// This acts as a bridge between GitDiffView (where users submit inline edit requests) and
  /// EmbeddedTerminalView (which sends the prompt to Claude). The flow is:
  /// 1. User submits inline edit request → `showTerminalWithPrompt` stores prompt here
  /// 2. Terminal view renders → reads prompt via `pendingPrompt(for:)`
  /// 3. Terminal sends prompt to Claude → `clearPendingPrompt` removes it
  ///
  /// - Note: Prompts are sent with a 100ms delay before pressing Enter to avoid race conditions
  ///   with the terminal's input buffer (see `EmbeddedTerminalView.sendPromptIfNeeded`).
  public var pendingTerminalPrompts: [String: String] = [:]

  /// Updates the terminal view state for a session
  public func setTerminalView(for sessionId: String, show: Bool) {
    if show {
      sessionsWithTerminalView.insert(sessionId)
    } else {
      sessionsWithTerminalView.remove(sessionId)
    }
    persistSessionsWithTerminalView()
  }

  /// Shows terminal view for a session with an initial prompt (for inline edit requests).
  /// Called when user submits an inline change request from GitDiffView.
  /// Stores the prompt temporarily so that when the terminal view renders,
  /// it can pass the prompt to EmbeddedTerminalView for the resume command.
  public func showTerminalWithPrompt(for session: CLISession, prompt: String) {
    // [CLISessionsVM] showTerminalWithPrompt called for session: \(session.id)")
    // [CLISessionsVM] prompt: \(prompt.prefix(100))...")
    // Start monitoring if not already
    if !monitoredSessionIds.contains(session.id) {
      // [CLISessionsVM] Starting monitoring for session")
      startMonitoring(session: session)
    }
    // Store the pending prompt
    pendingTerminalPrompts[session.id] = prompt
    // [CLISessionsVM] Stored prompt, pendingTerminalPrompts count: \(pendingTerminalPrompts.count)")
    // Show terminal view
    sessionsWithTerminalView.insert(session.id)
    // [CLISessionsVM] Terminal view enabled for session")
  }

  /// Returns the pending prompt for a session (read-only, safe during view body)
  public func pendingPrompt(for sessionId: String) -> String? {
    let prompt = pendingTerminalPrompts[sessionId]
    if prompt != nil {
      // [CLISessionsVM] pendingPrompt read for \(sessionId.prefix(8)): found prompt")
    }
    return prompt
  }

  /// Clears the pending prompt after terminal has started (call from onAppear)
  public func clearPendingPrompt(for sessionId: String) {
    // [CLISessionsVM] clearPendingPrompt called for \(sessionId.prefix(8))")
    pendingTerminalPrompts.removeValue(forKey: sessionId)
  }

  // MARK: - Terminal Management

  /// Gets an existing terminal or creates a new one for the given key.
  /// Key should be session ID for real sessions, or "pending-{pendingId}" for pending sessions.
  /// This preserves the terminal PTY across pending → real session transitions.
  public func getOrCreateTerminal(
    forKey key: String,
    sessionId: String?,
    projectPath: String,
    claudeClient: (any ClaudeCode)?,
    initialPrompt: String?
  ) -> TerminalContainerView {
    if let existing = activeTerminals[key] {
      // Send prompt to existing terminal if provided
      if let prompt = initialPrompt {
        existing.sendPromptIfNeeded(prompt)
      }
      return existing
    }

    let terminal = TerminalContainerView()
    terminal.configure(
      sessionId: sessionId,
      projectPath: projectPath,
      claudeClient: claudeClient,
      initialPrompt: initialPrompt
    )
    activeTerminals[key] = terminal
    return terminal
  }

  /// Removes the terminal for a given key
  public func removeTerminal(forKey key: String) {
    activeTerminals.removeValue(forKey: key)
  }

  /// Transfers terminal from pending key to real session ID (for pending → real transition)
  public func transferTerminal(fromPendingId pendingId: UUID, toSessionId sessionId: String) {
    let pendingKey = "pending-\(pendingId.uuidString)"
    if let terminal = activeTerminals.removeValue(forKey: pendingKey) {
      activeTerminals[sessionId] = terminal
    }
  }

  /// Sessions being started in Hub's embedded terminal (no session ID yet)
  public var pendingHubSessions: [PendingHubSession] = []

  /// Active terminal views keyed by worktree path
  /// Preserves terminal PTY across pending → real session transition
  public var activeTerminals: [String: TerminalContainerView] = [:]

  // MARK: - Monitoring State

  /// Set of session IDs currently being monitored
  public private(set) var monitoredSessionIds: Set<String> = []

  /// Current monitoring states keyed by session ID
  public private(set) var monitorStates: [String: SessionMonitorState] = [:]

  /// Combine cancellables for monitoring subscriptions (keyed by session ID)
  private var monitoringCancellables: [String: AnyCancellable] = [:]

  /// Whether to show the last message instead of the first message in session rows
  public var showLastMessage: Bool {
    didSet {
      UserDefaults.standard.set(showLastMessage, forKey: "CLISessionsShowLastMessage")
    }
  }

  /// Seconds to wait before triggering approval alert sound (default: 5)
  public var approvalTimeoutSeconds: Int {
    didSet {
      UserDefaults.standard.set(approvalTimeoutSeconds, forKey: "CLISessionsApprovalTimeout")
      // Update the file watcher with the new timeout
      Task {
        await fileWatcher.setApprovalTimeout(approvalTimeoutSeconds)
      }
    }
  }

  /// File watcher for real-time session monitoring
  public let fileWatcher: SessionFileWatcher

  // MARK: - Private

  private var subscriptionTask: Task<Void, Never>?
  private let persistenceKey = "CLISessionsSelectedRepositories"

  // MARK: - Initialization

  public init(monitorService: CLISessionMonitorService, claudeClient: ClaudeCode? = nil) {
    // [CLISessionsVM] init called")
    self.monitorService = monitorService
    self.searchService = GlobalSearchService()
    self.claudeClient = claudeClient
    self.fileWatcher = SessionFileWatcher()
    self.showLastMessage = UserDefaults.standard.bool(forKey: "CLISessionsShowLastMessage")

    // Load approval timeout with default of 5 seconds
    let savedTimeout = UserDefaults.standard.integer(forKey: "CLISessionsApprovalTimeout")
    self.approvalTimeoutSeconds = savedTimeout > 0 ? savedTimeout : 5

    setupSubscriptions()
    restorePersistedRepositories()
    requestNotificationPermissions()

    // Set initial timeout on file watcher
    Task {
      await fileWatcher.setApprovalTimeout(approvalTimeoutSeconds)
    }

    // [CLISessionsVM] init completed")
  }

  private func requestNotificationPermissions() {
    Task {
      await ApprovalNotificationService.shared.requestPermission()
    }
  }

  // MARK: - Subscriptions

  private func setupSubscriptions() {
    subscriptionTask = Task { [weak self] in
      guard let self = self else { return }

      for await repositories in self.monitorService.repositoriesPublisher.values {
        guard !Task.isCancelled else { break }

        await MainActor.run { [weak self] in
          guard let self = self else { return }

          // Preserve expanded state from current repositories
          self.selectedRepositories = self.mergePreservingExpandedState(
            current: self.selectedRepositories,
            updated: repositories
          )

          // Persist after state is updated to ensure consistency
          self.persistSelectedRepositories()

          // Check for pending auto-observe
          self.processPendingAutoObserve()
        }
      }
    }
  }

  /// Merges updated repositories while preserving expanded state from current repositories
  private func mergePreservingExpandedState(
    current: [SelectedRepository],
    updated: [SelectedRepository]
  ) -> [SelectedRepository] {
    // Build lookup for current expanded states
    var repoExpandedState: [String: Bool] = [:]
    var worktreeExpandedState: [String: Bool] = [:]

    for repo in current {
      repoExpandedState[repo.id] = repo.isExpanded
      for worktree in repo.worktrees {
        worktreeExpandedState[worktree.path] = worktree.isExpanded
      }
    }

    // Apply preserved states to updated repositories
    var result = updated
    for i in result.indices {
      if let expanded = repoExpandedState[result[i].id] {
        result[i].isExpanded = expanded
      }
      for j in result[i].worktrees.indices {
        if let expanded = worktreeExpandedState[result[i].worktrees[j].path] {
          result[i].worktrees[j].isExpanded = expanded
        }
      }
    }

    return result
  }

  // MARK: - Persistence

  private func restorePersistedRepositories() {
    Task {
      // [CLISessionsVM] restorePersistedRepositories called")
      guard let data = UserDefaults.standard.data(forKey: persistenceKey),
            let paths = try? JSONDecoder().decode([String].self, from: data) else {
        // [CLISessionsVM] No persisted repositories found")
        return
      }

      // [CLISessionsVM] Found \(paths.count) persisted paths: \(paths)")
      loadingState = .restoringRepositories
      // [CLISessionsVM] loadingState = .restoringRepositories")
      for path in paths {
        // [CLISessionsVM] Adding repository: \(path)")
        await monitorService.addRepository(path)
      }
      loadingState = .idle
      // [CLISessionsVM] loadingState = .idle")

      // Restore monitored sessions after all repositories have loaded
      restoreMonitoredSessions()
    }
  }

  private func persistSelectedRepositories() {
    let paths = selectedRepositories.map { $0.path }
    if let data = try? JSONEncoder().encode(paths) {
      UserDefaults.standard.set(data, forKey: persistenceKey)
    }
  }

  /// Persists the currently monitored session IDs to UserDefaults
  private func persistMonitoredSessions() {
    let sessionIds = Array(monitoredSessionIds)
    if let data = try? JSONEncoder().encode(sessionIds) {
      UserDefaults.standard.set(data, forKey: AgentHubDefaults.monitoredSessionIds)
    }
  }

  /// Persists which sessions have terminal view enabled
  private func persistSessionsWithTerminalView() {
    let sessionIds = Array(sessionsWithTerminalView)
    if let data = try? JSONEncoder().encode(sessionIds) {
      UserDefaults.standard.set(data, forKey: AgentHubDefaults.sessionsWithTerminalView)
    }
  }

  /// Restores monitored sessions from UserDefaults after repositories have loaded
  private func restoreMonitoredSessions() {
    // [CLISessionsVM] restoreMonitoredSessions called")

    // Restore monitored session IDs
    if let data = UserDefaults.standard.data(forKey: AgentHubDefaults.monitoredSessionIds),
       let sessionIds = try? JSONDecoder().decode([String].self, from: data) {
      // [CLISessionsVM] Found \(sessionIds.count) persisted monitored session IDs")

      for sessionId in sessionIds {
        // Find the session in loaded repositories
        if let session = findSession(byId: sessionId) {
          // Verify session file still exists
          if sessionFileExists(session: session) {
            // [CLISessionsVM] Restoring monitoring for session: \(sessionId.prefix(8))...")
            startMonitoring(session: session)
          } else {
            // [CLISessionsVM] Session file no longer exists: \(sessionId.prefix(8))...")
          }
        } else {
          // [CLISessionsVM] Session not found in loaded repos: \(sessionId.prefix(8))...")
        }
      }
    }

    // Restore terminal view state
    if let data = UserDefaults.standard.data(forKey: AgentHubDefaults.sessionsWithTerminalView),
       let sessionIds = try? JSONDecoder().decode([String].self, from: data) {
      // [CLISessionsVM] Found \(sessionIds.count) persisted sessions with terminal view")

      for sessionId in sessionIds {
        // Only restore terminal view for sessions that are actually monitored
        if monitoredSessionIds.contains(sessionId) {
          sessionsWithTerminalView.insert(sessionId)
        }
      }
    }

    // Expand repositories and worktrees that contain monitored sessions
    expandItemsContainingMonitoredSessions()
  }

  /// Expands repositories and worktrees that contain monitored sessions.
  ///
  /// Called during app launch after repositories and monitored sessions have been restored.
  /// This ensures users can immediately see their monitored sessions in the sidebar without
  /// having to manually expand each repository and worktree. The function iterates through
  /// all repositories and their worktrees, expanding any that contain at least one monitored
  /// session. Parent repositories are also expanded when any of their worktrees are expanded.
  private func expandItemsContainingMonitoredSessions() {
    guard !monitoredSessionIds.isEmpty else { return }

    for repoIndex in selectedRepositories.indices {
      var repoHasMonitoredSession = false

      for worktreeIndex in selectedRepositories[repoIndex].worktrees.indices {
        let worktree = selectedRepositories[repoIndex].worktrees[worktreeIndex]
        let hasMonitoredSession = worktree.sessions.contains { monitoredSessionIds.contains($0.id) }

        if hasMonitoredSession {
          selectedRepositories[repoIndex].worktrees[worktreeIndex].isExpanded = true
          repoHasMonitoredSession = true
        }
      }

      if repoHasMonitoredSession {
        selectedRepositories[repoIndex].isExpanded = true
      }
    }
  }

  /// Checks if the session file exists in ~/.claude
  private func sessionFileExists(session: CLISession) -> Bool {
    let claudeDataPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
    let encodedPath = session.projectPath.replacingOccurrences(of: "/", with: "-")
    let sessionFile = "\(claudeDataPath)/projects/\(encodedPath)/\(session.id).jsonl"
    return FileManager.default.fileExists(atPath: sessionFile)
  }

  // MARK: - Repository Management

  /// Opens a directory picker and adds the selected repository
  public func showAddRepositoryPicker() {
    // [CLISessionsVM] showAddRepositoryPicker called")
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.title = "Select Repository"
    panel.message = "Choose a git repository to monitor CLI sessions"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    if panel.runModal() == .OK, let url = panel.url {
      // [CLISessionsVM] User selected path: \(url.path)")
      addRepository(at: url.path)
    } else {
      // [CLISessionsVM] User cancelled picker")
    }
    #endif
  }

  /// Adds a repository at the given path
  public func addRepository(at path: String) {
    let repoName = URL(fileURLWithPath: path).lastPathComponent
    // [CLISessionsVM] addRepository called for: \(path) (name: \(repoName))")
    Task {
      // [CLISessionsVM] loadingState = .addingRepository(\(repoName))")
      loadingState = .addingRepository(name: repoName)
      // [CLISessionsVM] Calling monitorService.addRepository...")
      await monitorService.addRepository(path)
      // [CLISessionsVM] monitorService.addRepository completed")
      loadingState = .idle
      // [CLISessionsVM] loadingState = .idle")
    }
  }

  /// Removes a repository from monitoring
  public func removeRepository(_ repository: SelectedRepository) {
    // Stop monitoring all sessions from this repository
    for worktree in repository.worktrees {
      for session in worktree.sessions {
        if monitoredSessionIds.contains(session.id) {
          stopMonitoring(sessionId: session.id)
        }
      }
    }

    Task {
      await monitorService.removeRepository(repository.path)
    }
  }

  /// Creates a new worktree for the given repository with progress reporting
  /// - Parameters:
  ///   - repository: The repository to create the worktree in
  ///   - branchName: The name for the new branch
  ///   - directoryName: The directory name for the worktree
  ///   - baseBranch: The branch to base the new branch on (nil = HEAD)
  ///   - onProgress: Callback for progress updates
  public func createWorktree(
    for repository: SelectedRepository,
    branchName: String,
    directoryName: String,
    baseBranch: String?,
    onProgress: @escaping @Sendable (WorktreeCreationProgress) async -> Void
  ) async throws {
    _ = try await worktreeService.createWorktreeWithNewBranch(
      at: repository.path,
      newBranchName: branchName,
      directoryName: directoryName,
      startPoint: baseBranch,
      onProgress: onProgress
    )

    // Refresh to show the new worktree
    refresh()
  }

  /// Deletes a worktree
  /// - Parameter worktree: The worktree to delete
  public func deleteWorktree(_ worktree: WorktreeBranch) async {
    // [CLISessionsVM] deleteWorktree: \(worktree.path)")
    deletingWorktreePath = worktree.path

    do {
      try await worktreeService.removeWorktree(at: worktree.path)
      // [CLISessionsVM] Worktree deleted successfully")
      refresh()
    } catch {
      // [CLISessionsVM] Failed to delete worktree: \(error.localizedDescription)")
      worktreeDeletionError = WorktreeDeletionError(
        worktree: worktree,
        message: error.localizedDescription
      )
    }

    deletingWorktreePath = nil
  }

  /// Clears the worktree deletion error
  public func clearWorktreeDeletionError() {
    worktreeDeletionError = nil
  }

  /// Refreshes sessions for all selected repositories
  public func refresh() {
    // [CLISessionsVM] refresh called")
    Task {
      // [CLISessionsVM] loadingState = .refreshing")
      loadingState = .refreshing
      // [CLISessionsVM] Calling monitorService.refreshSessions...")
      await monitorService.refreshSessions()
      // [CLISessionsVM] refreshSessions completed")
      loadingState = .idle
      // [CLISessionsVM] loadingState = .idle")
    }
  }

  /// Toggles the expanded state of a repository
  public func toggleRepositoryExpanded(_ repository: SelectedRepository) {
    guard let index = selectedRepositories.firstIndex(where: { $0.id == repository.id }) else { return }
    selectedRepositories[index].isExpanded.toggle()
  }

  /// Toggles the expanded state of a worktree/branch
  public func toggleWorktreeExpanded(in repository: SelectedRepository, worktree: WorktreeBranch) {
    guard let repoIndex = selectedRepositories.firstIndex(where: { $0.id == repository.id }),
          let worktreeIndex = selectedRepositories[repoIndex].worktrees.firstIndex(where: { $0.id == worktree.id }) else {
      return
    }
    selectedRepositories[repoIndex].worktrees[worktreeIndex].isExpanded.toggle()
  }

  // MARK: - Session Actions

  /// Connects to a CLI session by launching Terminal with the resume command
  /// - Parameter session: The session to connect to
  /// - Returns: An error if the connection failed, nil on success
  public func connectToSession(_ session: CLISession) -> Error? {
    guard let claudeClient = claudeClient else {
      return NSError(
        domain: "CLISessionsViewModel",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Claude client not configured"]
      )
    }

    return TerminalLauncher.launchTerminalWithSession(
      session.id,
      claudeClient: claudeClient,
      projectPath: session.projectPath
    )
  }

  /// Opens Terminal with a new Claude session in the specified worktree/branch
  /// - Parameters:
  ///   - worktree: The worktree to open
  ///   - skipCheckout: If true, skips git checkout even for non-worktrees (already on correct branch)
  /// - Returns: An error if launching failed, nil on success
  public func openTerminalInWorktree(_ worktree: WorktreeBranch, skipCheckout: Bool = false) -> Error? {
    guard let claudeClient = claudeClient else {
      return NSError(
        domain: "CLISessionsViewModel",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Claude client not configured"]
      )
    }

    return TerminalLauncher.launchTerminalInPath(
      worktree.path,
      branchName: worktree.name,
      isWorktree: worktree.isWorktree,
      skipCheckout: skipCheckout,
      claudeClient: claudeClient
    )
  }

  /// Result of pre-flight check before opening terminal
  public struct TerminalOpenCheck: Sendable {
    public let needsCheckout: Bool
    public let hasUncommittedChanges: Bool
    public let currentBranch: String
    public let targetBranch: String
  }

  /// Checks conditions before opening terminal in a worktree
  /// - Parameter worktree: The worktree to check
  /// - Returns: Check results indicating if checkout is needed and if there are uncommitted changes
  public func checkBeforeOpeningTerminal(_ worktree: WorktreeBranch) async -> TerminalOpenCheck {
    // Worktrees don't need checkout - they're already on their branch
    guard !worktree.isWorktree else {
      return TerminalOpenCheck(
        needsCheckout: false,
        hasUncommittedChanges: false,
        currentBranch: worktree.name,
        targetBranch: worktree.name
      )
    }

    do {
      let currentBranch = try await worktreeService.getCurrentBranch(at: worktree.path)
      let needsCheckout = currentBranch != worktree.name

      // Only check for uncommitted changes if we need to checkout
      var hasChanges = false
      if needsCheckout {
        hasChanges = try await worktreeService.hasUncommittedChanges(at: worktree.path)
      }

      return TerminalOpenCheck(
        needsCheckout: needsCheckout,
        hasUncommittedChanges: hasChanges,
        currentBranch: currentBranch,
        targetBranch: worktree.name
      )
    } catch {
      // If we can't check, assume no checkout needed to avoid blocking
      // [CLISessionsVM] Error checking git status: \(error)")
      return TerminalOpenCheck(
        needsCheckout: false,
        hasUncommittedChanges: false,
        currentBranch: worktree.name,
        targetBranch: worktree.name
      )
    }
  }

  /// Opens terminal in worktree and sets up auto-observe for the new session
  /// - Parameters:
  ///   - worktree: The worktree to open
  ///   - skipCheckout: If true, skips git checkout even for non-worktrees
  /// - Returns: An error if launching failed, nil on success
  public func openTerminalAndAutoObserve(_ worktree: WorktreeBranch, skipCheckout: Bool = false) async -> Error? {
    // Capture existing session IDs in this worktree
    existingSessionIdsBeforeTerminal = Set(worktree.sessions.map { $0.id })
    pendingAutoObserveWorktreePath = worktree.path

    let error = openTerminalInWorktree(worktree, skipCheckout: skipCheckout)

    if error == nil {
      // Wait for session to be created, then refresh
      try? await Task.sleep(for: .seconds(1))
      refresh()
    } else {
      // Clear pending state on error
      pendingAutoObserveWorktreePath = nil
      existingSessionIdsBeforeTerminal = []
    }

    return error
  }

  /// Opens terminal in worktree and monitors the new session in Hub with terminal view enabled
  /// - Parameters:
  ///   - worktree: The worktree to open
  ///   - skipCheckout: If true, skips git checkout even for non-worktrees
  /// - Returns: An error if launching failed, nil on success
  /// Starts a new Claude session in the Hub's embedded terminal (not external terminal)
  /// - Parameter worktree: The worktree to start the session in
  public func startNewSessionInHub(_ worktree: WorktreeBranch) {
    // Each pending session gets a unique ID, so no need to clear existing terminals
    // Terminals are now keyed by session ID, not worktree path
    let pending = PendingHubSession(worktree: worktree)
    pendingHubSessions.append(pending)
#if DEBUG
    let encodedPath = worktree.path.replacingOccurrences(of: "/", with: "-")
    AppLogger.session.debug(
      "[StartInHub] pendingId=\(pending.id.uuidString, privacy: .public) worktreePath=\(worktree.path, privacy: .public) encodedPath=\(encodedPath, privacy: .public)"
    )
#endif

    // Watch for the new session file
    Task { @MainActor in
      await watchForNewSession(pending: pending, worktree: worktree)
    }
  }

  /// Removes a pending Hub session (e.g., if user cancels)
  public func cancelPendingSession(_ pending: PendingHubSession) {
    pendingHubSessions.removeAll { $0.id == pending.id }
  }

  /// Watches the project directory for a new session file
  @MainActor
  private func watchForNewSession(pending: PendingHubSession, worktree: WorktreeBranch) async {
    let claudeDataPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
    let encodedPath = worktree.path.replacingOccurrences(of: "/", with: "-")
    let projectDir = "\(claudeDataPath)/projects/\(encodedPath)"
#if DEBUG
    AppLogger.watcher.debug(
      "[WatchNewSession] pendingId=\(pending.id.uuidString, privacy: .public) projectDir=\(projectDir, privacy: .public) exists=\(FileManager.default.fileExists(atPath: projectDir))"
    )
#endif

    // Get existing session files BEFORE watching
    let existingFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: projectDir)) ?? [])
#if DEBUG
    let existingJsonlCount = existingFiles.filter { $0.hasSuffix(".jsonl") }.count
    AppLogger.watcher.debug(
      "[WatchNewSession] pendingId=\(pending.id.uuidString, privacy: .public) existingFiles=\(existingFiles.count) existingJsonl=\(existingJsonlCount)"
    )
#endif
    if let existingSessionFile = findRecentSessionFile(
      in: existingFiles,
      projectDir: projectDir,
      pendingStartedAt: pending.startedAt
    ) {
#if DEBUG
      AppLogger.watcher.debug(
        "[WatchNewSession] pendingId=\(pending.id.uuidString, privacy: .public) found existing session file \(existingSessionFile, privacy: .public)"
      )
#endif
      let sessionId = String(existingSessionFile.dropLast(6)) // Remove ".jsonl"
      handleNewSessionFound(sessionId: sessionId, pending: pending, worktree: worktree)
      return
    }

    // Open directory for watching
    let dirFd = open(projectDir, O_EVTONLY)
    guard dirFd >= 0 else {
#if DEBUG
      AppLogger.watcher.debug(
        "[WatchNewSession] pendingId=\(pending.id.uuidString, privacy: .public) open failed, falling back to poll"
      )
#endif
      // Directory doesn't exist yet - poll until it does
      await pollForNewSessionFallback(pending: pending, worktree: worktree)
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: dirFd,
      eventMask: [.write, .link, .attrib],
      queue: DispatchQueue.global(qos: .utility)
    )

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      var didFind = false

      source.setEventHandler { [weak self] in
        guard !didFind else { return }

        // Check for new .jsonl files
        guard let currentFiles = try? FileManager.default.contentsOfDirectory(atPath: projectDir) else { return }
        let newFiles = Set(currentFiles).subtracting(existingFiles)
        let newJsonlFiles = newFiles.filter { $0.hasSuffix(".jsonl") }
#if DEBUG
        if !newFiles.isEmpty {
          AppLogger.watcher.debug(
            "[WatchNewSession] pendingId=\(pending.id.uuidString, privacy: .public) event newFiles=\(newFiles.count) newJsonl=\(newJsonlFiles.count)"
          )
        }
#endif

        if let newFile = newJsonlFiles.first {
          didFind = true
          let sessionId = String(newFile.dropLast(6)) // Remove ".jsonl"

          Task { @MainActor in
            self?.handleNewSessionFound(sessionId: sessionId, pending: pending, worktree: worktree)
          }
          source.cancel()
          continuation.resume()
        }
      }

      source.setCancelHandler {
        close(dirFd)
      }

      source.resume()

      // Timeout after 60 seconds
      Task {
        try? await Task.sleep(for: .seconds(60))
        if !didFind {
          didFind = true // Prevent double resume
          source.cancel()
#if DEBUG
          AppLogger.watcher.debug(
            "[WatchNewSession] pendingId=\(pending.id.uuidString, privacy: .public) timed out waiting for session file"
          )
#endif
          Task { @MainActor in
            self.pendingHubSessions.removeAll { $0.id == pending.id }
          }
          continuation.resume()
        }
      }
    }
  }

  /// Picks a session file that was created around the time the pending session started.
  private func findRecentSessionFile(
    in existingFiles: Set<String>,
    projectDir: String,
    pendingStartedAt: Date
  ) -> String? {
    let candidates = existingFiles.filter { $0.hasSuffix(".jsonl") }
    guard !candidates.isEmpty else { return nil }

    let cutoff = pendingStartedAt.addingTimeInterval(-2)  // small buffer for timing jitter
    var newest: (file: String, createdAt: Date)?

    for file in candidates {
      let path = "\(projectDir)/\(file)"
      guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
      let createdAt = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
      guard let createdAt = createdAt, createdAt >= cutoff else { continue }

      if let current = newest {
        if createdAt > current.createdAt {
          newest = (file, createdAt)
        }
      } else {
        newest = (file, createdAt)
      }
    }

    return newest?.file
  }

  /// Handles when a new session file is detected
  private func handleNewSessionFound(sessionId: String, pending: PendingHubSession, worktree: WorktreeBranch) {
#if DEBUG
    AppLogger.session.debug(
      "[HandleNewSession] pendingId=\(pending.id.uuidString, privacy: .public) sessionId=\(sessionId, privacy: .public) worktreePath=\(worktree.path, privacy: .public) start"
    )
#endif
    // Refresh to get the real session object with retry loop
    Task {
      // Retry loop: wait up to 5 seconds for session to appear in selectedRepositories
      let maxAttempts = 25  // 25 × 200ms = 5 seconds

      for attempt in 1...maxAttempts {
        await monitorService.refreshSessions()

        // Wait for the publisher to propagate to selectedRepositories
        // The Combine subscription updates asynchronously on MainActor
        try? await Task.sleep(for: .milliseconds(200))

        // Find and monitor the new session (try path matching first)
        var found = false
        for repo in selectedRepositories {
          if let matchingWorktree = repo.worktrees.first(where: { $0.path == worktree.path }),
             let session = matchingWorktree.sessions.first(where: { $0.id == sessionId }) {
            // Remove pending only after finding the real session
            pendingHubSessions.removeAll { $0.id == pending.id }
            // Transfer terminal from pending key to real session ID
            transferTerminal(fromPendingId: pending.id, toSessionId: session.id)
            // Keep terminal view visible during transition
            sessionsWithTerminalView.insert(session.id)
            startMonitoring(session: session)
            found = true
            break
          }
        }

        if found { return }

        // Fallback: search by session ID alone if path matching failed
        for repo in selectedRepositories {
          for wt in repo.worktrees {
            if let session = wt.sessions.first(where: { $0.id == sessionId }) {
              pendingHubSessions.removeAll { $0.id == pending.id }
              // Transfer terminal from pending key to real session ID
              transferTerminal(fromPendingId: pending.id, toSessionId: session.id)
              // Keep terminal view visible during transition
              sessionsWithTerminalView.insert(session.id)
              startMonitoring(session: session)
              return
            }
          }
        }

        // Third fallback: check session file directly for new worktrees
        // This handles the case where history.jsonl hasn't been updated yet
        // TODO: Review - only triggers for worktrees with zero sessions
        let currentSessions = selectedRepositories
          .flatMap { $0.worktrees }
          .first { $0.path == worktree.path }?
          .sessions ?? []

        let claudeDataPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
        let encodedPath = worktree.path.replacingOccurrences(of: "/", with: "-")
        let sessionFilePath = "\(claudeDataPath)/projects/\(encodedPath)/\(sessionId).jsonl"
        if currentSessions.isEmpty && FileManager.default.fileExists(atPath: sessionFilePath) {
          // Session file exists but not in history.jsonl yet - create directly
          let newSession = CLISession(
            id: sessionId,
            projectPath: worktree.path,
            branchName: worktree.name,
            isWorktree: worktree.isWorktree,
            lastActivityAt: Date(),
            messageCount: 0,
            isActive: true,
            firstMessage: nil,
            lastMessage: nil
          )

          for repoIndex in selectedRepositories.indices {
            if let wtIndex = selectedRepositories[repoIndex].worktrees.firstIndex(where: { $0.path == worktree.path }) {
              selectedRepositories[repoIndex].worktrees[wtIndex].sessions.insert(newSession, at: 0)
              break
            }
          }

          pendingHubSessions.removeAll { $0.id == pending.id }
          transferTerminal(fromPendingId: pending.id, toSessionId: sessionId)
          sessionsWithTerminalView.insert(sessionId)
          startMonitoring(session: newSession)
#if DEBUG
          AppLogger.session.info(
            "[HandleNewSession-Fallback] sessionId=\(sessionId, privacy: .public) created session directly from file (new worktree)"
          )
#endif
          return
        }

        // Log retry attempt (only if not the last attempt)
        if attempt < maxAttempts {
#if DEBUG
          AppLogger.session.debug(
            "[HandleNewSession] sessionId=\(sessionId, privacy: .public) not found, retrying (\(attempt)/\(maxAttempts))"
          )
#endif
        }
      }

      // If still not found after all attempts, log warning
      // Keep pending session visible (terminal continues working)
#if DEBUG
      AppLogger.session.warning(
        "[HandleNewSession] sessionId=\(sessionId, privacy: .public) not found after \(maxAttempts) attempts"
      )
#endif
    }
  }

  /// Fallback: polls for the project directory to be created, then watches it
  @MainActor
  private func pollForNewSessionFallback(pending: PendingHubSession, worktree: WorktreeBranch) async {
    let claudeDataPath = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
    let encodedPath = worktree.path.replacingOccurrences(of: "/", with: "-")
    let projectDir = "\(claudeDataPath)/projects/\(encodedPath)"
#if DEBUG
    AppLogger.watcher.debug(
      "[PollNewSession] pendingId=\(pending.id.uuidString, privacy: .public) projectDir=\(projectDir, privacy: .public) start"
    )
#endif

    // Wait for directory to be created, then watch it
    for _ in 0..<60 {
      try? await Task.sleep(for: .seconds(1))

      if FileManager.default.fileExists(atPath: projectDir) {
#if DEBUG
        AppLogger.watcher.debug(
          "[PollNewSession] pendingId=\(pending.id.uuidString, privacy: .public) projectDir exists, restarting watch"
        )
#endif
        // Directory exists now - restart watching
        await watchForNewSession(pending: pending, worktree: worktree)
        return
      }
    }

    // Timeout
#if DEBUG
    AppLogger.watcher.debug(
      "[PollNewSession] pendingId=\(pending.id.uuidString, privacy: .public) timed out waiting for project dir"
    )
#endif
    pendingHubSessions.removeAll { $0.id == pending.id }
  }

  /// Copies the full session ID to the clipboard
  /// - Parameter session: The session whose ID to copy
  public func copySessionId(_ session: CLISession) {
    #if canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(session.id, forType: .string)
    #endif
  }

  // MARK: - Computed Properties

  /// Whether any loading operation is in progress
  public var isLoading: Bool {
    loadingState.isLoading
  }

  /// Whether any repositories are selected
  public var hasRepositories: Bool {
    !selectedRepositories.isEmpty
  }

  /// Total number of sessions across all repositories
  public var totalSessionCount: Int {
    selectedRepositories.reduce(0) { $0 + $1.totalSessionCount }
  }

  /// Total number of active sessions across all repositories
  public var activeSessionCount: Int {
    selectedRepositories.reduce(0) { $0 + $1.activeSessionCount }
  }

  /// All sessions flattened from all repositories
  public var allSessions: [CLISession] {
    selectedRepositories.flatMap { repo in
      repo.worktrees.flatMap { $0.sessions }
    }
  }

  /// Find a session by its ID
  public func findSession(byId sessionId: String) -> CLISession? {
    allSessions.first { $0.id == sessionId }
  }

  // MARK: - Monitoring Management

  /// Toggle monitoring for a session
  public func toggleMonitoring(for session: CLISession) {
    if monitoredSessionIds.contains(session.id) {
      stopMonitoring(sessionId: session.id)
    } else {
      startMonitoring(session: session)
    }
  }

  /// Start monitoring a session
  public func startMonitoring(session: CLISession) {
    guard !monitoredSessionIds.contains(session.id) else { return }

    monitoredSessionIds.insert(session.id)
    persistMonitoredSessions()

    // Subscribe to state updates
    let cancellable = fileWatcher.statePublisher
      .filter { $0.sessionId == session.id }
      .receive(on: DispatchQueue.main)
      .sink { [weak self] update in
        self?.monitorStates[session.id] = update.state
      }

    monitoringCancellables[session.id] = cancellable

    // Start watching
    Task {
      await fileWatcher.startMonitoring(
        sessionId: session.id,
        projectPath: session.projectPath
      )
    }
  }

  /// Stop monitoring a session
  public func stopMonitoring(session: CLISession) {
    stopMonitoring(sessionId: session.id)
  }

  /// Stop monitoring by session ID
  public func stopMonitoring(sessionId: String) {
    monitoredSessionIds.remove(sessionId)
    sessionsWithTerminalView.remove(sessionId)
    monitorStates.removeValue(forKey: sessionId)
    monitoringCancellables.removeValue(forKey: sessionId)

    persistMonitoredSessions()
    persistSessionsWithTerminalView()

    Task {
      await fileWatcher.stopMonitoring(sessionId: sessionId)
    }
  }

  /// Check if a session is being monitored
  public func isMonitoring(sessionId: String) -> Bool {
    monitoredSessionIds.contains(sessionId)
  }

  /// Get all currently monitored sessions with their states
  public var monitoredSessions: [(session: CLISession, state: SessionMonitorState?)] {
    allSessions
      .filter { monitoredSessionIds.contains($0.id) }
      .map { session in
        (session: session, state: monitorStates[session.id])
      }
  }

  // MARK: - Search

  /// Performs a search across all sessions with debouncing
  public func performSearch() {
    // Cancel any existing search task
    searchTask?.cancel()

    guard !searchQuery.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    isSearching = true

    searchTask = Task { [weak self] in
      // Debounce: wait 300ms
      try? await Task.sleep(for: .milliseconds(300))

      guard !Task.isCancelled, let self = self else { return }

      let query = self.searchQuery
      let filterPath = self.searchFilterPath
      let results = await self.searchService.search(query: query, filterPath: filterPath)

      guard !Task.isCancelled else { return }

      await MainActor.run { [weak self] in
        guard let self = self else { return }
        self.searchResults = results
        self.isSearching = false
        self.hasPerformedSearch = true
      }
    }
  }

  /// Clears the search query and results
  public func clearSearch() {
    searchTask?.cancel()
    searchQuery = ""
    searchResults = []
    isSearching = false
    hasPerformedSearch = false
  }

  /// Called when user selects a search result - adds the repo and clears search
  /// - Parameter result: The selected search result
  public func selectSearchResult(_ result: SessionSearchResult) {
    let sessionId = result.id
    let projectPath = result.projectPath

    // Store for auto-observe
    pendingAutoObserveSessionId = sessionId
    pendingAutoObserveProjectPath = projectPath

    // Add the repository if not already present
    if !selectedRepositories.contains(where: { $0.path == projectPath }) {
      addRepository(at: projectPath)
    } else {
      // Repo already exists - process immediately
      processPendingAutoObserve()
    }

    // Clear search
    clearSearch()
  }

  /// Processes pending auto-observe: finds the session, expands its container, and starts monitoring
  private func processPendingAutoObserve() {
    // Handle search result auto-observe (existing logic)
    if let sessionId = pendingAutoObserveSessionId,
       let projectPath = pendingAutoObserveProjectPath {
      // Clear pending state
      pendingAutoObserveSessionId = nil
      pendingAutoObserveProjectPath = nil

      // Find the repository containing this project path
      guard let repoIndex = selectedRepositories.firstIndex(where: {
        $0.path == projectPath || $0.worktrees.contains { $0.path == projectPath }
      }) else {
        return
      }

      // Expand the repository
      selectedRepositories[repoIndex].isExpanded = true

      // Find the worktree containing the session
      for worktreeIndex in selectedRepositories[repoIndex].worktrees.indices {
        let worktree = selectedRepositories[repoIndex].worktrees[worktreeIndex]
        if let session = worktree.sessions.first(where: { $0.id == sessionId }) {
          // Expand the worktree
          selectedRepositories[repoIndex].worktrees[worktreeIndex].isExpanded = true

          // Start monitoring the session
          startMonitoring(session: session)
          return
        }
      }
    }

    // Handle terminal-opened session auto-observe (new logic)
    if let worktreePath = pendingAutoObserveWorktreePath {
      pendingAutoObserveWorktreePath = nil

      // Find worktree and detect new sessions
      for repo in selectedRepositories {
        if let worktree = repo.worktrees.first(where: { $0.path == worktreePath }) {
          // Find new session (one that wasn't there before)
          let newSession = worktree.sessions.first { session in
            !existingSessionIdsBeforeTerminal.contains(session.id)
          }

          existingSessionIdsBeforeTerminal = []

          if let session = newSession {
            // Expand repo and worktree, start monitoring
            if let repoIndex = selectedRepositories.firstIndex(where: { $0.id == repo.id }) {
              selectedRepositories[repoIndex].isExpanded = true
              if let wtIndex = selectedRepositories[repoIndex].worktrees.firstIndex(where: { $0.id == worktree.id }) {
                selectedRepositories[repoIndex].worktrees[wtIndex].isExpanded = true
              }
            }

            // If started via "Start in Hub", mark session to show terminal view
            if pendingHubSessionWithTerminal {
              sessionsWithTerminalView.insert(session.id)
              pendingHubSessionWithTerminal = false
            }

            startMonitoring(session: session)
          }
          return
        }
      }
      existingSessionIdsBeforeTerminal = []
    }
  }

  // MARK: - Search Filter

  /// Opens a folder picker to select a repository for filtering search results
  public func showSearchFilterPicker() {
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.title = "Filter by Repository"
    panel.message = "Select a repository to filter search results"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    if panel.runModal() == .OK, let url = panel.url {
      searchFilterPath = url.path
      // Re-run search with new filter if there's an active query
      if !searchQuery.isEmpty {
        performSearch()
      }
    }
    #endif
  }

  /// Clears the search filter
  public func clearSearchFilter() {
    searchFilterPath = nil
    // Re-run search without filter if there's an active query
    if !searchQuery.isEmpty {
      performSearch()
    }
  }
}
