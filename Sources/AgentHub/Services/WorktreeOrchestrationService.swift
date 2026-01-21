//
//  WorktreeOrchestrationService.swift
//  AgentHub
//
//  Created by Assistant on 1/15/26.
//

import Foundation
import ClaudeCodeSDK

/// Service for orchestrating parallel worktree creation and Claude session launching.
@MainActor
public final class WorktreeOrchestrationService {

  // MARK: - Properties

  private let gitService: GitWorktreeService
  private let monitorService: CLISessionMonitorService
  private let claudeClient: ClaudeCode

  /// Callback for progress updates
  public var onProgress: ((OrchestrationProgress) -> Void)?

  /// Callback for detailed worktree creation progress
  public var onWorktreeProgress: ((WorktreeCreationProgress) -> Void)?

  // MARK: - Initialization

  public init(
    gitService: GitWorktreeService,
    monitorService: CLISessionMonitorService,
    claudeClient: ClaudeCode
  ) {
    self.gitService = gitService
    self.monitorService = monitorService
    self.claudeClient = claudeClient
  }

  // MARK: - Public Methods

  /// Execute an orchestration plan - creates worktrees and launches Claude sessions
  /// - Parameter plan: The orchestration plan from Claude
  /// - Returns: Array of created worktree paths
  public func executePlan(_ plan: OrchestrationPlan) async throws -> [String] {
    onProgress?(.starting(sessionCount: plan.sessions.count))

    // Ensure the repository is added to the monitor service
    _ = await monitorService.addRepository(plan.modulePath)

    var createdPaths: [String] = []
    var errors: [String] = []

    // Create worktrees sequentially to avoid git conflicts
    for (index, session) in plan.sessions.enumerated() {
      onProgress?(.creatingWorktree(
        index: index + 1,
        total: plan.sessions.count,
        branchName: session.branchName
      ))

      do {
        let worktreePath = try await createWorktreeForSession(
          session: session,
          modulePath: plan.modulePath
        )
        createdPaths.append(worktreePath)

        // Launch terminal with Claude immediately
        onProgress?(.launchingSession(
          index: index + 1,
          total: plan.sessions.count,
          branchName: session.branchName
        ))

        launchClaudeSession(
          path: worktreePath,
          branchName: session.branchName,
          prompt: session.prompt
        )

        // Delay between terminal launches to prevent macOS race condition
        if index < plan.sessions.count - 1 {
          try? await Task.sleep(for: .milliseconds(800))
        }

      } catch {
        errors.append("\(session.branchName): \(error.localizedDescription)")
      }
    }

    // Poll for sessions to appear in UI (also handles expansion)
    await pollForNewSessions(
      branchNames: plan.sessions.map { $0.branchName },
      repositoryPath: plan.modulePath
    )

    onProgress?(.completed(
      successCount: createdPaths.count,
      errorCount: errors.count
    ))

    return createdPaths
  }

  // MARK: - Private Methods

  private func createWorktreeForSession(
    session: OrchestrationSession,
    modulePath: String
  ) async throws -> String {
    // Capture callback for use in Sendable closure
    let progressCallback = onWorktreeProgress

    // Create worktree with the session's branch name
    let worktreePath = try await gitService.createWorktreeWithNewBranch(
      at: modulePath,
      newBranchName: session.branchName,
      directoryName: session.branchName,
      startPoint: nil
    ) { progress in
      // Forward detailed progress to callback on MainActor
      Task { @MainActor in
        progressCallback?(progress)
      }
    }

    return worktreePath
  }

  private func launchClaudeSession(
    path: String,
    branchName: String,
    prompt: String
  ) {
    // Launch terminal with Claude and initial prompt
    _ = TerminalLauncher.launchTerminalInPath(
      path,
      branchName: branchName,
      isWorktree: true,
      skipCheckout: true,
      claudeClient: claudeClient,
      initialPrompt: prompt
    )
  }

  /// Polls for sessions to appear after worktree creation and expands worktrees when found
  private func pollForNewSessions(
    branchNames: [String],
    repositoryPath: String
  ) async {
    let maxWaitTime: Double = 10.0  // seconds
    let pollInterval: Double = 0.5  // seconds
    let startTime = Date()
    var foundBranches: Set<String> = []

    while Date().timeIntervalSince(startTime) < maxWaitTime {
      await monitorService.refreshSessions()

      // Get fresh repositories and check for sessions
      var repositories = await monitorService.getSelectedRepositories()
      var needsUpdate = false

      if let repoIndex = repositories.firstIndex(where: { $0.path == repositoryPath }) {
        // Expand the repository itself
        if !repositories[repoIndex].isExpanded {
          repositories[repoIndex].isExpanded = true
          needsUpdate = true
        }

        for worktreeIndex in repositories[repoIndex].worktrees.indices {
          let worktree = repositories[repoIndex].worktrees[worktreeIndex]
          if branchNames.contains(worktree.name) && !worktree.sessions.isEmpty {
            foundBranches.insert(worktree.name)

            // Expand the worktree when sessions are found
            if !repositories[repoIndex].worktrees[worktreeIndex].isExpanded {
              repositories[repoIndex].worktrees[worktreeIndex].isExpanded = true
              needsUpdate = true
            }
          }
        }

        // Update state if any expansion changed
        if needsUpdate {
          await monitorService.setSelectedRepositories(repositories)
        }
      }

      onProgress?(.waitingForSessions(found: foundBranches.count, total: branchNames.count))

      if foundBranches.count == branchNames.count {
        return
      }

      try? await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
    }

    // Final refresh on timeout
    await monitorService.refreshSessions()
  }
}

// MARK: - Progress Enum

/// Progress updates during orchestration
public enum OrchestrationProgress {
  case starting(sessionCount: Int)
  case creatingWorktree(index: Int, total: Int, branchName: String)
  case launchingSession(index: Int, total: Int, branchName: String)
  case waitingForSessions(found: Int, total: Int)
  case completed(successCount: Int, errorCount: Int)

  public var message: String {
    switch self {
    case .starting(let count):
      return "Spawning \(count) sessions..."
    case .creatingWorktree(let index, let total, let branch):
      return "Creating worktree \(index)/\(total): \(branch)"
    case .launchingSession(let index, let total, let branch):
      return "Launching session \(index)/\(total): \(branch)"
    case .waitingForSessions(let found, let total):
      return "Waiting for sessions... (\(found)/\(total))"
    case .completed(let success, let errors):
      if errors > 0 {
        return "Completed: \(success) sessions, \(errors) failed"
      }
      return "Completed: \(success) sessions launched"
    }
  }
}
