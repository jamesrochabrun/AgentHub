//
//  SessionGitHubQuickAccessCoordinatorTests.swift
//  AgentHubTests
//
//  Tests for shared session card GitHub quick access coordination
//

import Foundation
import Testing

@testable import AgentHubCore

private func makeCoordinatorPR(number: Int) -> GitHubPullRequest {
  GitHubPullRequest(
    number: number,
    title: "PR \(number)",
    body: nil,
    state: "OPEN",
    url: "https://github.com/test/repo/pull/\(number)",
    headRefName: "feature-branch",
    baseRefName: "main",
    author: GitHubAuthor(login: "testuser", name: "Test User"),
    createdAt: .now,
    updatedAt: .now,
    isDraft: false,
    mergeable: "MERGEABLE",
    additions: 10,
    deletions: 5,
    changedFiles: 3,
    reviewDecision: nil,
    statusCheckRollup: nil,
    labels: nil,
    reviewRequests: nil,
    comments: nil
  )
}

private func makeCoordinatorConfiguration(
  missingPRPollInterval: TimeInterval = 0.02,
  existingPRPollInterval: TimeInterval = 0.03,
  idleTimeout: TimeInterval = 0.05,
  errorBackoff: [TimeInterval] = [0.02, 0.03, 0.04]
) -> SessionGitHubQuickAccessCoordinatorConfiguration {
  SessionGitHubQuickAccessCoordinatorConfiguration(
    missingPRPollInterval: missingPRPollInterval,
    existingPRPollInterval: existingPRPollInterval,
    idleTimeout: idleTimeout,
    errorBackoff: errorBackoff
  )
}

@Suite("SessionGitHubQuickAccessCoordinator")
struct SessionGitHubQuickAccessCoordinatorTests {

  @Test("deduplicates refreshes for multiple visible subscribers on the same repo key")
  func deduplicatesVisibleSubscribers() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeCoordinatorPR(number: 1)
    let coordinator = SessionGitHubQuickAccessCoordinator(
      service: service,
      configuration: makeCoordinatorConfiguration(idleTimeout: 1)
    )

    let firstSubscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")
    let secondSubscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")

    try? await Task.sleep(for: .milliseconds(20))

    #expect(service.getCurrentBranchPRCallCount == 1)

    await coordinator.unsubscribe(subscriptionID: firstSubscription.id)
    await coordinator.unsubscribe(subscriptionID: secondSubscription.id)
  }

  @Test("activity during an in-flight refresh does not launch a duplicate GitHub fetch")
  func coalescesActivityDuringRefresh() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRDelay = 0.06
    service.currentBranchPRResult = nil
    let coordinator = SessionGitHubQuickAccessCoordinator(
      service: service,
      configuration: makeCoordinatorConfiguration(missingPRPollInterval: 0.2, idleTimeout: 1)
    )

    let subscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")
    try? await Task.sleep(for: .milliseconds(10))
    #expect(service.getCurrentBranchPRCallCount == 1)

    let activityAt = Date.now
    await coordinator.recordActivity(projectPath: "/tmp/repo", branchName: "main", at: activityAt)
    await coordinator.recordActivity(
      projectPath: "/tmp/repo",
      branchName: "main",
      at: activityAt.addingTimeInterval(0.01)
    )

    try? await Task.sleep(for: .milliseconds(30))
    #expect(service.getCurrentBranchPRCallCount == 1)

    try? await Task.sleep(for: .milliseconds(90))
    #expect(service.getCurrentBranchPRCallCount == 1)

    await coordinator.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("last visible subscriber disappearing cancels future refreshes")
  func unsubscribeCancelsPolling() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = nil
    let coordinator = SessionGitHubQuickAccessCoordinator(
      service: service,
      configuration: makeCoordinatorConfiguration(missingPRPollInterval: 0.02, idleTimeout: 1)
    )

    let subscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")
    await coordinator.recordActivity(projectPath: "/tmp/repo", branchName: "main", at: .now)
    try? await Task.sleep(for: .milliseconds(55))
    let callCountBeforeUnsubscribe = service.getCurrentBranchPRCallCount

    await coordinator.unsubscribe(subscriptionID: subscription.id)
    try? await Task.sleep(for: .milliseconds(55))

    #expect(callCountBeforeUnsubscribe >= 2)
    #expect(service.getCurrentBranchPRCallCount == callCountBeforeUnsubscribe)
  }

  @Test("idle timeout pauses refresh until new activity arrives")
  func idleTimeoutPausesAndResumes() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = nil
    let coordinator = SessionGitHubQuickAccessCoordinator(
      service: service,
      configuration: makeCoordinatorConfiguration(missingPRPollInterval: 0.02, idleTimeout: 0.03)
    )

    let subscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")
    await coordinator.recordActivity(projectPath: "/tmp/repo", branchName: "main", at: .now)
    try? await Task.sleep(for: .milliseconds(25))
    let callCountBeforeIdlePause = service.getCurrentBranchPRCallCount

    try? await Task.sleep(for: .milliseconds(35))
    #expect(service.getCurrentBranchPRCallCount == callCountBeforeIdlePause)

    await coordinator.recordActivity(projectPath: "/tmp/repo", branchName: "main", at: .now)
    try? await Task.sleep(for: .milliseconds(10))

    #expect(service.getCurrentBranchPRCallCount == callCountBeforeIdlePause + 1)
    await coordinator.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("terminal GitHub errors pause refresh until activity reactivates it")
  func terminalErrorsPauseUntilReactivated() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResults = [
      .failure(GitHubCLIError.notAuthenticated),
      .success(makeCoordinatorPR(number: 7)),
    ]
    let coordinator = SessionGitHubQuickAccessCoordinator(
      service: service,
      configuration: makeCoordinatorConfiguration(missingPRPollInterval: 0.02, idleTimeout: 1)
    )

    let subscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")
    try? await Task.sleep(for: .milliseconds(20))
    #expect(service.getCurrentBranchPRCallCount == 1)

    try? await Task.sleep(for: .milliseconds(40))
    #expect(service.getCurrentBranchPRCallCount == 1)

    await coordinator.recordActivity(projectPath: "/tmp/repo", branchName: "main", at: .now)
    try? await Task.sleep(for: .milliseconds(20))

    #expect(service.getCurrentBranchPRCallCount == 2)
    await coordinator.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("fresh cached PR activity keeps the remaining cadence instead of forcing an immediate refresh")
  func freshCacheActivityPreservesCadence() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResults = [
      .success(makeCoordinatorPR(number: 1)),
      .success(makeCoordinatorPR(number: 2)),
    ]
    let coordinator = SessionGitHubQuickAccessCoordinator(
      service: service,
      configuration: makeCoordinatorConfiguration(existingPRPollInterval: 0.15, idleTimeout: 1)
    )

    let subscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")
    try? await Task.sleep(for: .milliseconds(20))
    #expect(service.getCurrentBranchPRCallCount == 1)

    await coordinator.recordActivity(projectPath: "/tmp/repo", branchName: "main", at: .now)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(service.getCurrentBranchPRCallCount == 1)

    try? await Task.sleep(for: .milliseconds(140))
    #expect(service.getCurrentBranchPRCallCount == 2)

    await coordinator.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("stale resubscribe triggers a fresh fetch")
  func staleResubscribeTriggersRefresh() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResults = [
      .success(makeCoordinatorPR(number: 1)),
      .success(makeCoordinatorPR(number: 2)),
    ]
    let coordinator = SessionGitHubQuickAccessCoordinator(
      service: service,
      configuration: makeCoordinatorConfiguration(existingPRPollInterval: 0.03, idleTimeout: 1)
    )

    let firstSubscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")
    await coordinator.recordActivity(projectPath: "/tmp/repo", branchName: "main", at: .now)
    try? await Task.sleep(for: .milliseconds(20))
    await coordinator.unsubscribe(subscriptionID: firstSubscription.id)

    try? await Task.sleep(for: .milliseconds(35))

    let secondSubscription = await coordinator.subscribe(projectPath: "/tmp/repo", branchName: "main")
    await coordinator.recordActivity(projectPath: "/tmp/repo", branchName: "main", at: .now)
    try? await Task.sleep(for: .milliseconds(20))

    #expect(service.getCurrentBranchPRCallCount >= 2)
    await coordinator.unsubscribe(subscriptionID: secondSubscription.id)
  }
}
