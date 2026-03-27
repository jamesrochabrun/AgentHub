//
//  SessionGitHubQuickAccessViewModel.swift
//  AgentHub
//
//  Lightweight GitHub state for session card quick access
//

import Foundation

@MainActor
@Observable
public final class SessionGitHubQuickAccessViewModel {

  public private(set) var currentBranchPR: GitHubPullRequest?

  private let service: any GitHubCLIServiceProtocol
  private var loadedRepositoryKey: String?
  private var pollingTask: Task<Void, Never>?
  private var lastActivityDate: Date = .now
  private var currentProjectPath: String?
  private var currentBranchName: String?

  /// How long the session can be idle before polling pauses
  private static let idleTimeout: TimeInterval = 5 * 60 // 5 minutes

  public init(service: any GitHubCLIServiceProtocol = GitHubCLIService()) {
    self.service = service
  }

  public func load(projectPath: String, branchName: String?) async {
    let repositoryKey = Self.repositoryKey(projectPath: projectPath, branchName: branchName)

    // Reset state when the branch/project changes
    if loadedRepositoryKey != repositoryKey {
      loadedRepositoryKey = repositoryKey
      currentBranchPR = nil
      stopPolling()
    }

    currentProjectPath = projectPath
    currentBranchName = branchName
    lastActivityDate = .now

    guard await service.isInstalled() else { return }
    guard !Task.isCancelled else { return }
    guard await service.isAuthenticated(at: projectPath) else { return }
    guard !Task.isCancelled else { return }

    do {
      let pullRequest = try await service.getCurrentBranchPR(at: projectPath)
      guard !Task.isCancelled, loadedRepositoryKey == repositoryKey else { return }
      currentBranchPR = pullRequest
    } catch {
      guard !Task.isCancelled, loadedRepositoryKey == repositoryKey else { return }
      currentBranchPR = nil
    }

    // Start polling to detect newly created PRs or state changes
    startPolling(projectPath: projectPath, branchName: branchName)
  }

  /// Call when session activity is detected (status change, new message, tool use)
  /// to keep polling alive or resume it after idle pause.
  public func notifySessionActivity() {
    lastActivityDate = .now

    // Resume polling if it was paused due to inactivity
    if pollingTask == nil, let projectPath = currentProjectPath {
      startPolling(projectPath: projectPath, branchName: currentBranchName)
    }
  }

  public func stopPolling() {
    pollingTask?.cancel()
    pollingTask = nil
  }

  // MARK: - Private

  private func startPolling(projectPath: String, branchName: String?) {
    pollingTask?.cancel()
    let repositoryKey = Self.repositoryKey(projectPath: projectPath, branchName: branchName)
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        // Poll more frequently when no PR is found yet
        let interval: Duration = self?.currentBranchPR == nil ? .seconds(30) : .seconds(120)
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        guard let self, self.loadedRepositoryKey == repositoryKey else { return }

        // Pause polling if the session has been idle too long
        let idleDuration = Date.now.timeIntervalSince(self.lastActivityDate)
        if idleDuration > Self.idleTimeout {
          self.pollingTask = nil
          return
        }

        do {
          let pr = try await self.service.getCurrentBranchPR(at: projectPath)
          guard !Task.isCancelled, self.loadedRepositoryKey == repositoryKey else { return }
          self.currentBranchPR = pr
        } catch {
          // Silently continue polling on errors
        }
      }
    }
  }

  static func repositoryKey(projectPath: String, branchName: String?) -> String {
    "\(projectPath)|\(branchName ?? "")"
  }
}
