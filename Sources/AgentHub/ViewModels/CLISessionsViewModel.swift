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
  private let claudeClient: ClaudeCode?

  // MARK: - State

  public private(set) var selectedRepositories: [SelectedRepository] = []
  public private(set) var loadingState: CLILoadingState = .idle
  public private(set) var error: Error?

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
      persistSelectedRepositories()
      print("[CLISessionsVM] Persisted repositories")
      loadingState = .idle
      print("[CLISessionsVM] loadingState = .idle")
    }
  }

  /// Removes a repository from monitoring
  public func removeRepository(_ repository: SelectedRepository) {
    Task {
      await monitorService.removeRepository(repository.path)
      persistSelectedRepositories()
    }
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
}
