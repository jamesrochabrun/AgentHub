//
//  GitHubViewModelObservationTests.swift
//  AgentHubTests
//
//  Tests for GitHubViewModel observation integration.
//

import Foundation
import Testing

@testable import AgentHubGitHub

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

private func makeViewModelObservationPR(
  number: Int = 1,
  title: String = "Observed PR"
) -> GitHubPullRequest {
  GitHubPullRequest(
    number: number,
    title: title,
    body: nil,
    state: "OPEN",
    url: "https://github.com/test/repo/pull/\(number)",
    headRefName: "feature",
    baseRefName: "main",
    author: GitHubAuthor(login: "testuser", name: nil),
    createdAt: .now,
    updatedAt: .now,
    isDraft: false,
    mergeable: "MERGEABLE",
    additions: 4,
    deletions: 1,
    changedFiles: 2,
    reviewDecision: nil,
    statusCheckRollup: nil,
    labels: nil,
    reviewRequests: nil,
    comments: nil
  )
}

private func makeViewModelObservationCheck(name: String = "Build") -> GitHubCheckRun {
  GitHubCheckRun(name: name, status: "COMPLETED", conclusion: "SUCCESS", bucket: nil, detailsUrl: nil)
}

private final class MockGitHubPRObservationService: GitHubPRObservationServiceProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<GitHubPRObservationSnapshot>.Continuation] = [:]
  private var targetsByID: [UUID: GitHubPRObservationTarget] = [:]

  private(set) var subscribedTargets: [GitHubPRObservationTarget] = []
  private(set) var unsubscribedIDs: [UUID] = []
  private(set) var refreshedTargets: [GitHubPRObservationTarget] = []
  private(set) var activityTargets: [GitHubPRObservationTarget] = []

  func subscribe(
    to target: GitHubPRObservationTarget,
    refreshOnSubscribe: Bool
  ) async -> GitHubPRObservationSubscription {
    let id = UUID()
    var continuation: AsyncStream<GitHubPRObservationSnapshot>.Continuation?
    let updates = AsyncStream<GitHubPRObservationSnapshot> { streamContinuation in
      continuation = streamContinuation
    }

    lock.withLock {
      subscribedTargets.append(target)
      targetsByID[id] = target
      if let continuation {
        continuations[id] = continuation
      }
    }

    continuation?.yield(.initial(target: target))
    return GitHubPRObservationSubscription(id: id, updates: updates)
  }

  func unsubscribe(subscriptionID: UUID) async {
    let continuation = lock.withLock {
      unsubscribedIDs.append(subscriptionID)
      targetsByID.removeValue(forKey: subscriptionID)
      return continuations.removeValue(forKey: subscriptionID)
    }
    continuation?.finish()
  }

  func refresh(_ target: GitHubPRObservationTarget) async {
    lock.withLock {
      refreshedTargets.append(target)
    }
  }

  func recordActivity(for target: GitHubPRObservationTarget, at: Date) async {
    lock.withLock {
      activityTargets.append(target)
    }
  }

  func publish(_ snapshot: GitHubPRObservationSnapshot) {
    let continuations = lock.withLock {
      self.continuations.filter { id, _ in
        targetsByID[id] == snapshot.target
      }.map(\.value)
    }
    for continuation in continuations {
      continuation.yield(snapshot)
    }
  }

  func activeSubscriptionCount(for target: GitHubPRObservationTarget) -> Int {
    lock.withLock {
      targetsByID.values.count { $0 == target }
    }
  }
}

@Suite("GitHubViewModel Observation")
struct GitHubViewModelObservationTests {

  @Test("setup starts current branch observation and applies snapshots")
  @MainActor
  func setupStartsCurrentBranchObservation() async {
    let service = MockGitHubCLIService()
    service.repoInfoResult = GitHubRepoInfo(
      owner: "test",
      name: "repo",
      fullName: "test/repo",
      defaultBranch: "main",
      isPrivate: false,
      url: "https://github.com/test/repo"
    )
    let observer = MockGitHubPRObservationService()
    let viewModel = GitHubViewModel(service: service, observationService: observer)
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")

    await viewModel.setup(repoPath: "/tmp/repo", branchName: "feature")
    try? await Task.sleep(for: .milliseconds(10))

    #expect(observer.subscribedTargets == [target])

    observer.publish(GitHubPRObservationSnapshot(
      target: target,
      pullRequest: makeViewModelObservationPR(number: 12),
      checks: [makeViewModelObservationCheck()],
      state: .ready,
      lastRefreshedAt: .now
    ))
    try? await Task.sleep(for: .milliseconds(10))

    #expect(viewModel.currentBranchPR?.number == 12)
    #expect(viewModel.currentBranchChecks.count == 1)
    #expect(viewModel.currentBranchObservationState == .ready)
  }

  @Test("selectPR starts selected PR observation and updates checks")
  @MainActor
  func selectPRStartsSelectedObservation() async {
    let service = MockGitHubCLIService()
    service.repoInfoResult = GitHubRepoInfo(
      owner: "test",
      name: "repo",
      fullName: "test/repo",
      defaultBranch: "main",
      isPrivate: false,
      url: "https://github.com/test/repo"
    )
    service.pullRequestDiffResult = ""
    service.pullRequestFilesResult = []
    service.reviewCommentsResult = []
    let observer = MockGitHubPRObservationService()
    let viewModel = GitHubViewModel(service: service, observationService: observer)
    await viewModel.setup(repoPath: "/tmp/repo", branchName: "feature")

    viewModel.selectPR(makeViewModelObservationPR(number: 44, title: "Initial"))
    try? await Task.sleep(for: .milliseconds(10))

    let target = GitHubPRObservationTarget.pullRequest(projectPath: "/tmp/repo", number: 44)
    #expect(observer.subscribedTargets.contains(target))

    observer.publish(GitHubPRObservationSnapshot(
      target: target,
      pullRequest: makeViewModelObservationPR(number: 44, title: "Updated"),
      checks: [makeViewModelObservationCheck(name: "Tests")],
      state: .ready,
      lastRefreshedAt: .now
    ))
    try? await Task.sleep(for: .milliseconds(10))

    #expect(viewModel.selectedPR?.title == "Updated")
    #expect(viewModel.checks.map(\.name) == ["Tests"])
    #expect(viewModel.loadedChecksPRNumber == 44)
  }
}
