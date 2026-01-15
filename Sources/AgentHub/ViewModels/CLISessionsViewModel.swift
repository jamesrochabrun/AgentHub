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
  private let claudeClient: ClaudeCode?
  private let worktreeService = GitWorktreeService()

  // MARK: - State

  public private(set) var selectedRepositories: [SelectedRepository] = []
  public private(set) var loadingState: CLILoadingState = .idle
  public private(set) var error: Error?

  // MARK: - Search State

  public var searchQuery: String = ""
  public private(set) var searchResults: [SessionSearchResult] = []
  public private(set) var isSearching: Bool = false
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
    print("[CLISessionsVM] init called")
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

    print("[CLISessionsVM] init completed")
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
          self.selectedRepositories = repositories

          // Persist after state is updated to ensure consistency
          self.persistSelectedRepositories()

          // Check for pending auto-observe
          self.processPendingAutoObserve()
        }
      }
    }
  }

  // MARK: - Persistence

  private func restorePersistedRepositories() {
    Task {
      print("[CLISessionsVM] restorePersistedRepositories called")
      guard let data = UserDefaults.standard.data(forKey: persistenceKey),
            let paths = try? JSONDecoder().decode([String].self, from: data) else {
        print("[CLISessionsVM] No persisted repositories found")
        return
      }

      print("[CLISessionsVM] Found \(paths.count) persisted paths: \(paths)")
      loadingState = .restoringRepositories
      print("[CLISessionsVM] loadingState = .restoringRepositories")
      for path in paths {
        print("[CLISessionsVM] Adding repository: \(path)")
        await monitorService.addRepository(path)
      }
      loadingState = .idle
      print("[CLISessionsVM] loadingState = .idle")
    }
  }

  private func persistSelectedRepositories() {
    let paths = selectedRepositories.map { $0.path }
    if let data = try? JSONEncoder().encode(paths) {
      UserDefaults.standard.set(data, forKey: persistenceKey)
    }
  }

  // MARK: - Repository Management

  /// Opens a directory picker and adds the selected repository
  public func showAddRepositoryPicker() {
    print("[CLISessionsVM] showAddRepositoryPicker called")
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.title = "Select Repository"
    panel.message = "Choose a git repository to monitor CLI sessions"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false

    if panel.runModal() == .OK, let url = panel.url {
      print("[CLISessionsVM] User selected path: \(url.path)")
      addRepository(at: url.path)
    } else {
      print("[CLISessionsVM] User cancelled picker")
    }
    #endif
  }

  /// Adds a repository at the given path
  public func addRepository(at path: String) {
    let repoName = URL(fileURLWithPath: path).lastPathComponent
    print("[CLISessionsVM] addRepository called for: \(path) (name: \(repoName))")
    Task {
      print("[CLISessionsVM] loadingState = .addingRepository(\(repoName))")
      loadingState = .addingRepository(name: repoName)
      print("[CLISessionsVM] Calling monitorService.addRepository...")
      await monitorService.addRepository(path)
      print("[CLISessionsVM] monitorService.addRepository completed")
      loadingState = .idle
      print("[CLISessionsVM] loadingState = .idle")
    }
  }

  /// Removes a repository from monitoring
  public func removeRepository(_ repository: SelectedRepository) {
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

  /// Refreshes sessions for all selected repositories
  public func refresh() {
    print("[CLISessionsVM] refresh called")
    Task {
      print("[CLISessionsVM] loadingState = .refreshing")
      loadingState = .refreshing
      print("[CLISessionsVM] Calling monitorService.refreshSessions...")
      await monitorService.refreshSessions()
      print("[CLISessionsVM] refreshSessions completed")
      loadingState = .idle
      print("[CLISessionsVM] loadingState = .idle")
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
      print("[CLISessionsVM] Error checking git status: \(error)")
      return TerminalOpenCheck(
        needsCheckout: false,
        hasUncommittedChanges: false,
        currentBranch: worktree.name,
        targetBranch: worktree.name
      )
    }
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

  // MARK: - Monitoring Management

  /// Toggle monitoring for a session
  public func toggleMonitoring(for session: CLISession) {
    if monitoredSessionIds.contains(session.id) {
      stopMonitoring(session: session)
    } else {
      startMonitoring(session: session)
    }
  }

  /// Start monitoring a session
  public func startMonitoring(session: CLISession) {
    guard !monitoredSessionIds.contains(session.id) else { return }

    monitoredSessionIds.insert(session.id)

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
    monitorStates.removeValue(forKey: sessionId)
    monitoringCancellables.removeValue(forKey: sessionId)

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
      }
    }
  }

  /// Clears the search query and results
  public func clearSearch() {
    searchTask?.cancel()
    searchQuery = ""
    searchResults = []
    isSearching = false
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
    guard let sessionId = pendingAutoObserveSessionId,
          let projectPath = pendingAutoObserveProjectPath else {
      return
    }

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
