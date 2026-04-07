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

  private var coordinator: (any SessionGitHubQuickAccessCoordinatorProtocol)?
  private let service: any GitHubCLIServiceProtocol
  private var loadedRepositoryKey: String?
  private var subscriptionID: UUID?
  private var subscriptionTask: Task<Void, Never>?
  private var currentProjectPath: String?
  private var currentBranchName: String?

  public init(
    coordinator: (any SessionGitHubQuickAccessCoordinatorProtocol)? = nil,
    service: any GitHubCLIServiceProtocol = GitHubCLIService()
  ) {
    self.coordinator = coordinator
    self.service = service
  }

  public func load(
    projectPath: String,
    branchName: String?,
    coordinator: (any SessionGitHubQuickAccessCoordinatorProtocol)? = nil
  ) async {
    let repositoryKey = Self.repositoryKey(projectPath: projectPath, branchName: branchName)
    if let coordinator {
      self.coordinator = coordinator
    }

    let isUsingSharedCoordinator = self.coordinator != nil
    let alreadySubscribed = loadedRepositoryKey == repositoryKey && (!isUsingSharedCoordinator || subscriptionTask != nil)
    guard !alreadySubscribed else { return }

    if loadedRepositoryKey != repositoryKey {
      currentBranchPR = nil
    }
    await stopCurrentSubscription()

    loadedRepositoryKey = repositoryKey
    currentProjectPath = projectPath
    currentBranchName = branchName

    if let coordinator = self.coordinator {
      let subscription = await coordinator.subscribe(projectPath: projectPath, branchName: branchName)
      subscriptionID = subscription.id
      subscriptionTask = Task { [weak self] in
        for await currentBranchPR in subscription.updates {
          guard let self else { return }
          self.apply(currentBranchPR: currentBranchPR, for: repositoryKey)
        }
      }
      return
    }

    currentBranchPR = nil

    do {
      let pullRequest = try await service.getCurrentBranchPR(at: projectPath)
      guard !Task.isCancelled, loadedRepositoryKey == repositoryKey else { return }
      currentBranchPR = pullRequest
    } catch {
      guard !Task.isCancelled, loadedRepositoryKey == repositoryKey else { return }
      currentBranchPR = nil
    }
  }

  public func notifySessionActivity(at activityDate: Date = .now) async {
    guard let coordinator,
          let projectPath = currentProjectPath else {
      return
    }

    await coordinator.recordActivity(
      projectPath: projectPath,
      branchName: currentBranchName,
      at: activityDate
    )
  }

  public func stopPolling() {
    let subscriptionID = self.subscriptionID
    let coordinator = self.coordinator

    subscriptionTask?.cancel()
    subscriptionTask = nil
    self.subscriptionID = nil

    if let subscriptionID, let coordinator {
      Task {
        await coordinator.unsubscribe(subscriptionID: subscriptionID)
      }
    }
  }

  // MARK: - Private

  private func stopCurrentSubscription() async {
    let subscriptionID = self.subscriptionID
    let coordinator = self.coordinator

    subscriptionTask?.cancel()
    subscriptionTask = nil
    self.subscriptionID = nil

    if let subscriptionID, let coordinator {
      await coordinator.unsubscribe(subscriptionID: subscriptionID)
    }
  }

  private func apply(currentBranchPR: GitHubPullRequest?, for repositoryKey: String) {
    guard loadedRepositoryKey == repositoryKey else { return }
    self.currentBranchPR = currentBranchPR
  }

  public nonisolated static func repositoryKey(projectPath: String, branchName: String?) -> String {
    "\(projectPath)|\(branchName ?? "")"
  }
}
