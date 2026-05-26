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
  public private(set) var currentBranchChecks: [GitHubCheckRun] = []
  public private(set) var observationState: GitHubPRObservationState = .idle
  public private(set) var lastRefreshedAt: Date?

  public var ciSummary: GitHubCISummary {
    GitHubCISummary(checks: currentBranchChecks)
  }

  private var coordinator: (any SessionGitHubQuickAccessCoordinatorProtocol)?
  private var observationService: (any GitHubPRObservationServiceProtocol)?
  private let service: any GitHubCLIServiceProtocol
  private var loadedRepositoryKey: String?
  private var subscriptionID: UUID?
  private var observationSubscriptionID: UUID?
  private var subscriptionTask: Task<Void, Never>?
  private var currentProjectPath: String?
  private var currentBranchName: String?
  private var currentObservationTarget: GitHubPRObservationTarget?

  public init(
    coordinator: (any SessionGitHubQuickAccessCoordinatorProtocol)? = nil,
    observationService: (any GitHubPRObservationServiceProtocol)? = nil,
    service: any GitHubCLIServiceProtocol = GitHubCLIService()
  ) {
    self.coordinator = coordinator
    self.observationService = observationService
    self.service = service
  }

  public func load(
    projectPath: String,
    branchName: String?,
    linkedPullRequestNumber: Int? = nil,
    coordinator: (any SessionGitHubQuickAccessCoordinatorProtocol)? = nil,
    observationService: (any GitHubPRObservationServiceProtocol)? = nil,
    refreshOnSubscribe: Bool = true,
    recordInitialActivity: Bool = true,
    forceRefreshLinkedPullRequest: Bool = true
  ) async {
    let repositoryKey = Self.repositoryKey(
      projectPath: projectPath,
      branchName: branchName,
      linkedPullRequestNumber: linkedPullRequestNumber
    )
    if let coordinator {
      self.coordinator = coordinator
    }
    if let observationService {
      self.observationService = observationService
    }

    let isUsingSharedSource = self.coordinator != nil || self.observationService != nil
    let alreadySubscribed = loadedRepositoryKey == repositoryKey && (!isUsingSharedSource || subscriptionTask != nil)
    guard !alreadySubscribed else { return }

    if loadedRepositoryKey != repositoryKey {
      clearState()
    }
    await stopCurrentSubscription()

    loadedRepositoryKey = repositoryKey
    currentProjectPath = projectPath
    currentBranchName = branchName

    if let observationService = self.observationService {
      let target = observationTarget(
        projectPath: projectPath,
        branchName: branchName,
        linkedPullRequestNumber: linkedPullRequestNumber
      )
      currentObservationTarget = target
      let subscription = await observationService.subscribe(to: target, refreshOnSubscribe: refreshOnSubscribe)
      observationSubscriptionID = subscription.id
      subscriptionTask = Task { [weak self] in
        for await snapshot in subscription.updates {
          guard let self else { return }
          self.apply(snapshot: snapshot, for: repositoryKey)
        }
      }
      if recordInitialActivity {
        await observationService.recordActivity(for: target, at: .now)
      }
      if linkedPullRequestNumber != nil, forceRefreshLinkedPullRequest {
        await observationService.refresh(target)
      }
      return
    } else if let coordinator = self.coordinator {
      let subscription = await coordinator.subscribe(projectPath: projectPath, branchName: branchName)
      subscriptionID = subscription.id
      subscriptionTask = Task { [weak self] in
        for await currentBranchPR in subscription.updates {
          guard let self else { return }
          self.apply(currentBranchPR: currentBranchPR, for: repositoryKey, state: .ready)
        }
      }
      return
    }

    clearState()

    do {
      let pullRequest: GitHubPullRequest?
      if let linkedPullRequestNumber {
        pullRequest = try await service.getPullRequest(number: linkedPullRequestNumber, at: projectPath)
      } else {
        pullRequest = try await service.getCurrentBranchPR(at: projectPath)
      }
      guard !Task.isCancelled, loadedRepositoryKey == repositoryKey else { return }
      currentBranchPR = pullRequest
      observationState = .ready
      lastRefreshedAt = .now
    } catch {
      guard !Task.isCancelled, loadedRepositoryKey == repositoryKey else { return }
      clearState(state: .ready)
    }
  }

  public func notifySessionActivity(at activityDate: Date = .now) async {
    guard let projectPath = currentProjectPath else {
      return
    }

    if let observationService, let target = currentObservationTarget {
      await observationService.recordActivity(
        for: target,
        at: activityDate
      )
      if target.pullRequestNumber != nil {
        await observationService.refresh(target)
      }
    } else if let coordinator {
      await coordinator.recordActivity(
        projectPath: projectPath,
        branchName: currentBranchName,
        at: activityDate
      )
    }
  }

  public func stopPolling() {
    let subscriptionID = self.subscriptionID
    let coordinator = self.coordinator

    subscriptionTask?.cancel()
    subscriptionTask = nil
    self.subscriptionID = nil
    let observationSubscriptionID = self.observationSubscriptionID
    let observationService = self.observationService
    self.observationSubscriptionID = nil

    if let subscriptionID, let coordinator {
      Task {
        await coordinator.unsubscribe(subscriptionID: subscriptionID)
      }
    }
    if let observationSubscriptionID, let observationService {
      Task {
        await observationService.unsubscribe(subscriptionID: observationSubscriptionID)
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
    let observationSubscriptionID = self.observationSubscriptionID
    let observationService = self.observationService
    self.observationSubscriptionID = nil

    if let subscriptionID, let coordinator {
      await coordinator.unsubscribe(subscriptionID: subscriptionID)
    }
    if let observationSubscriptionID, let observationService {
      await observationService.unsubscribe(subscriptionID: observationSubscriptionID)
    }
  }

  private func apply(
    currentBranchPR: GitHubPullRequest?,
    for repositoryKey: String,
    state: GitHubPRObservationState
  ) {
    guard loadedRepositoryKey == repositoryKey else { return }
    self.currentBranchPR = currentBranchPR
    currentBranchChecks = []
    observationState = state
    lastRefreshedAt = .now
  }

  private func apply(snapshot: GitHubPRObservationSnapshot, for repositoryKey: String) {
    guard loadedRepositoryKey == repositoryKey else { return }
    currentBranchPR = snapshot.pullRequest
    currentBranchChecks = snapshot.checks
    observationState = snapshot.state
    lastRefreshedAt = snapshot.lastRefreshedAt
  }

  private func clearState(state: GitHubPRObservationState = .idle) {
    currentBranchPR = nil
    currentBranchChecks = []
    observationState = state
    lastRefreshedAt = nil
    currentObservationTarget = nil
  }

  private nonisolated func observationTarget(
    projectPath: String,
    branchName: String?,
    linkedPullRequestNumber: Int?
  ) -> GitHubPRObservationTarget {
    if let linkedPullRequestNumber {
      return .pullRequest(projectPath: projectPath, number: linkedPullRequestNumber)
    }
    return .currentBranch(projectPath: projectPath, branchName: branchName)
  }

  public nonisolated static func repositoryKey(
    projectPath: String,
    branchName: String?,
    linkedPullRequestNumber: Int? = nil
  ) -> String {
    if let linkedPullRequestNumber {
      return "\(projectPath)|\(branchName ?? "")|pr:\(linkedPullRequestNumber)"
    }
    return "\(projectPath)|\(branchName ?? "")"
  }
}
