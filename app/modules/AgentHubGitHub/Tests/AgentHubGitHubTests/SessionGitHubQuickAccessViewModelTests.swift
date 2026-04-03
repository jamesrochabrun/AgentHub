//
//  SessionGitHubQuickAccessViewModelTests.swift
//  AgentHubTests
//
//  Tests for session card GitHub quick access state
//

import Foundation
import Testing

@testable import AgentHubGitHub

private func makeQuickAccessPR(
  number: Int = 1,
  title: String = "Quick Access PR",
  changedFiles: Int = 3,
  additions: Int = 10,
  deletions: Int = 5
) -> GitHubPullRequest {
  GitHubPullRequest(
    number: number,
    title: title,
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
    additions: additions,
    deletions: deletions,
    changedFiles: changedFiles,
    reviewDecision: nil,
    statusCheckRollup: nil,
    labels: nil,
    reviewRequests: nil,
    comments: nil
  )
}

actor MockSessionGitHubQuickAccessCoordinator: SessionGitHubQuickAccessCoordinatorProtocol {
  private var continuations: [UUID: AsyncStream<GitHubPullRequest?>.Continuation] = [:]
  private var subscriptionKeys: [UUID: String] = [:]
  private var cachedPRs: [String: GitHubPullRequest?] = [:]

  private(set) var subscribeCallCount = 0
  private(set) var unsubscribeCallCount = 0
  private(set) var recordedActivities: [(String, Date)] = []

  func subscribe(projectPath: String, branchName: String?) async -> SessionGitHubQuickAccessSubscription {
    subscribeCallCount += 1
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: projectPath,
      branchName: branchName
    )
    let subscriptionID = UUID()

    var continuation: AsyncStream<GitHubPullRequest?>.Continuation?
    let updates = AsyncStream<GitHubPullRequest?> { streamContinuation in
      continuation = streamContinuation
    }

    guard let continuation else {
      return SessionGitHubQuickAccessSubscription(id: subscriptionID, updates: updates)
    }

    continuations[subscriptionID] = continuation
    subscriptionKeys[subscriptionID] = repositoryKey
    continuation.yield(cachedPRs[repositoryKey] ?? nil)

    return SessionGitHubQuickAccessSubscription(id: subscriptionID, updates: updates)
  }

  func unsubscribe(subscriptionID: UUID) async {
    unsubscribeCallCount += 1
    continuations.removeValue(forKey: subscriptionID)?.finish()
    subscriptionKeys.removeValue(forKey: subscriptionID)
  }

  func recordActivity(projectPath: String, branchName: String?, at: Date) async {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: projectPath,
      branchName: branchName
    )
    recordedActivities.append((repositoryKey, at))
  }

  func publish(_ currentBranchPR: GitHubPullRequest?, projectPath: String, branchName: String?) async {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: projectPath,
      branchName: branchName
    )
    cachedPRs[repositoryKey] = currentBranchPR

    for (subscriptionID, continuation) in continuations where subscriptionKeys[subscriptionID] == repositoryKey {
      continuation.yield(currentBranchPR)
    }
  }

  func activeSubscriptionCount(for projectPath: String, branchName: String?) async -> Int {
    let repositoryKey = SessionGitHubQuickAccessViewModel.repositoryKey(
      projectPath: projectPath,
      branchName: branchName
    )
    return subscriptionKeys.values.count { $0 == repositoryKey }
  }
}

@Suite("SessionGitHubQuickAccessViewModel")
struct SessionGitHubQuickAccessViewModelTests {

  @Test("loads current branch PR when no shared coordinator is available")
  @MainActor
  func loadsCurrentBranchPRFallback() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = makeQuickAccessPR(number: 187, changedFiles: 12, additions: 4195, deletions: 0)
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")

    #expect(viewModel.currentBranchPR?.number == 187)
    #expect(mock.getCurrentBranchPRCallCount == 1)
    #expect(mock.getCurrentBranchPRRepoPath == "/tmp/repo")
  }

  @Test("silences service errors and keeps empty quick access state without shared coordinator")
  @MainActor
  func silencesFallbackErrors() async {
    let mock = MockGitHubCLIService()
    mock.errorToThrow = GitHubCLIError.noRemoteRepository
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")

    #expect(viewModel.currentBranchPR == nil)
    #expect(mock.getCurrentBranchPRCallCount == 1)
  }

  @Test("subscribes to shared coordinator updates")
  @MainActor
  func subscribesToCoordinator() async {
    let coordinator = MockSessionGitHubQuickAccessCoordinator()
    let viewModel = SessionGitHubQuickAccessViewModel(coordinator: coordinator)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")
    await coordinator.publish(makeQuickAccessPR(number: 42), projectPath: "/tmp/repo", branchName: "main")
    try? await Task.sleep(for: .milliseconds(10))

    #expect(viewModel.currentBranchPR?.number == 42)
    #expect(await coordinator.subscribeCallCount == 1)
    #expect(await coordinator.activeSubscriptionCount(for: "/tmp/repo", branchName: "main") == 1)
  }

  @Test("same repo load does not create duplicate subscriptions")
  @MainActor
  func avoidsDuplicateSubscriptions() async {
    let coordinator = MockSessionGitHubQuickAccessCoordinator()
    let viewModel = SessionGitHubQuickAccessViewModel(coordinator: coordinator)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")
    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")

    #expect(await coordinator.subscribeCallCount == 1)
    #expect(await coordinator.activeSubscriptionCount(for: "/tmp/repo", branchName: "main") == 1)
  }

  @Test("stopPolling unsubscribes and same repo can subscribe again on reappear")
  @MainActor
  func stopPollingAllowsResubscribe() async {
    let coordinator = MockSessionGitHubQuickAccessCoordinator()
    let viewModel = SessionGitHubQuickAccessViewModel(coordinator: coordinator)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")
    viewModel.stopPolling()
    try? await Task.sleep(for: .milliseconds(10))

    #expect(await coordinator.activeSubscriptionCount(for: "/tmp/repo", branchName: "main") == 0)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")

    #expect(await coordinator.subscribeCallCount == 2)
    #expect(await coordinator.unsubscribeCallCount == 1)
    #expect(await coordinator.activeSubscriptionCount(for: "/tmp/repo", branchName: "main") == 1)
  }

  @Test("reloads when the branch changes for the same repo")
  @MainActor
  func reloadsWhenBranchChanges() async {
    let coordinator = MockSessionGitHubQuickAccessCoordinator()
    let viewModel = SessionGitHubQuickAccessViewModel(coordinator: coordinator)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/one")
    await coordinator.publish(makeQuickAccessPR(number: 1), projectPath: "/tmp/repo", branchName: "feature/one")
    try? await Task.sleep(for: .milliseconds(10))

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/two")
    await coordinator.publish(makeQuickAccessPR(number: 2), projectPath: "/tmp/repo", branchName: "feature/two")
    try? await Task.sleep(for: .milliseconds(10))

    #expect(viewModel.currentBranchPR?.number == 2)
    #expect(await coordinator.subscribeCallCount == 2)
    #expect(await coordinator.unsubscribeCallCount == 1)
  }

  @Test("notifySessionActivity forwards timestamp to shared coordinator")
  @MainActor
  func notifySessionActivityForwardsTimestamp() async {
    let coordinator = MockSessionGitHubQuickAccessCoordinator()
    let viewModel = SessionGitHubQuickAccessViewModel(coordinator: coordinator)
    let activityDate = Date.now.addingTimeInterval(-5)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")
    await viewModel.notifySessionActivity(at: activityDate)

    let activities = await coordinator.recordedActivities
    #expect(activities.count == 1)
    #expect(activities.first?.0 == "/tmp/repo|main")
    #expect(activities.first?.1 == activityDate)
  }
}
