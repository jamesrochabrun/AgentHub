//
//  GitHubPRObservationServiceTests.swift
//  AgentHubTests
//
//  Tests for shared GitHub PR/check observation.
//

import Foundation
import Testing

@testable import AgentHubGitHub

private func makeObservedPR(number: Int = 1, title: String = "Observed PR") -> GitHubPullRequest {
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
    additions: 10,
    deletions: 2,
    changedFiles: 3,
    reviewDecision: nil,
    statusCheckRollup: nil,
    labels: nil,
    reviewRequests: nil,
    comments: nil
  )
}

private func makeObservedCheck(
  name: String,
  status: String = "COMPLETED",
  conclusion: String? = "SUCCESS",
  bucket: String? = nil
) -> GitHubCheckRun {
  GitHubCheckRun(name: name, status: status, conclusion: conclusion, bucket: bucket, detailsUrl: nil)
}

private func makeObservationConfiguration(
  pendingPollInterval: TimeInterval = 0.02,
  settledPollInterval: TimeInterval = 0.2,
  idleTimeout: TimeInterval = 1,
  errorBackoff: [TimeInterval] = [0.02, 0.03]
) -> GitHubPRObservationConfiguration {
  GitHubPRObservationConfiguration(
    pendingPollInterval: pendingPollInterval,
    settledPollInterval: settledPollInterval,
    idleTimeout: idleTimeout,
    errorBackoff: errorBackoff
  )
}

private actor ObservationSnapshotCollector {
  private var values: [GitHubPRObservationSnapshot] = []

  func append(_ snapshot: GitHubPRObservationSnapshot) {
    values.append(snapshot)
  }

  func snapshots() -> [GitHubPRObservationSnapshot] {
    values
  }
}

@Suite("GitHubPRObservationService")
struct GitHubPRObservationServiceTests {

  @Test("deduplicates subscribers for the same current-branch target")
  func deduplicatesSubscribers() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(number: 10)
    service.checksResult = [makeObservedCheck(name: "Build")]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration()
    )
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")

    let first = await observer.subscribe(to: target)
    let second = await observer.subscribe(to: target)
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(service.getCurrentBranchPRCallCount == 1)
    #expect(service.getChecksCallCount == 1)

    await observer.unsubscribe(subscriptionID: first.id)
    await observer.unsubscribe(subscriptionID: second.id)
  }

  @Test("selected PR subscription fetches PR metadata and checks")
  func selectedPRFetchesMetadataAndChecks() async {
    let service = MockGitHubCLIService()
    service.pullRequestResult = makeObservedPR(number: 42)
    service.checksResult = [
      makeObservedCheck(name: "Build"),
      makeObservedCheck(name: "Tests", conclusion: "FAILURE"),
    ]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration()
    )
    let target = GitHubPRObservationTarget.pullRequest(projectPath: "/tmp/repo", number: 42)

    let subscription = await observer.subscribe(to: target)
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(30))

    #expect(service.getPullRequestCallCount == 1)
    #expect(service.getPullRequestNumber == 42)
    #expect(service.getChecksCallCount == 1)
    #expect(service.getChecksPRNumber == 42)

    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("current branch PR publishes when no checks are reported")
  func currentBranchPRPublishesWhenNoChecksAreReported() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(number: 88)
    service.checksResult = []
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration()
    )
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")
    let collector = ObservationSnapshotCollector()

    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)
    let collectionTask = Task {
      for await snapshot in subscription.updates {
        await collector.append(snapshot)
      }
    }
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(30))

    let readySnapshot = await collector.snapshots().last { $0.state == .ready }
    #expect(readySnapshot?.pullRequest?.number == 88)
    #expect(readySnapshot?.checks.isEmpty == true)
    #expect(readySnapshot?.ciSummary.total == 0)
    #expect(service.getCurrentBranchPRCallCount == 1)
    #expect(service.getChecksCallCount == 1)

    collectionTask.cancel()
    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("current branch PR still publishes when checks fail")
  func currentBranchPRStillPublishesWhenChecksFail() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(number: 89)
    service.checksResults = [.failure(GitHubCLIError.timeout)]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration()
    )
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")
    let collector = ObservationSnapshotCollector()

    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)
    let collectionTask = Task {
      for await snapshot in subscription.updates {
        await collector.append(snapshot)
      }
    }
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(30))

    let degradedSnapshot = await collector.snapshots().last { snapshot in
      if case .error = snapshot.state { return true }
      return false
    }
    #expect(degradedSnapshot?.pullRequest?.number == 89)
    #expect(degradedSnapshot?.checks.isEmpty == true)
    #expect(service.getCurrentBranchPRCallCount == 1)
    #expect(service.getChecksCallCount == 1)

    collectionTask.cancel()
    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("selected PR still publishes metadata when checks fail")
  func selectedPRStillPublishesMetadataWhenChecksFail() async {
    let service = MockGitHubCLIService()
    service.pullRequestResult = makeObservedPR(number: 90)
    service.checksResults = [.failure(GitHubCLIError.timeout)]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration()
    )
    let target = GitHubPRObservationTarget.pullRequest(projectPath: "/tmp/repo", number: 90)
    let collector = ObservationSnapshotCollector()

    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)
    let collectionTask = Task {
      for await snapshot in subscription.updates {
        await collector.append(snapshot)
      }
    }
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(30))

    let degradedSnapshot = await collector.snapshots().last { snapshot in
      if case .error = snapshot.state { return true }
      return false
    }
    #expect(degradedSnapshot?.pullRequest?.number == 90)
    #expect(degradedSnapshot?.checks.isEmpty == true)
    #expect(service.getPullRequestCallCount == 1)
    #expect(service.getChecksCallCount == 1)

    collectionTask.cancel()
    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("subscribe can defer initial fetch until recent activity")
  func subscribeCanDeferInitialFetchUntilRecentActivity() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(number: 11)
    service.checksResult = [makeObservedCheck(name: "Build")]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration(idleTimeout: 1)
    )
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")

    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(service.getCurrentBranchPRCallCount == 0)

    await observer.recordActivity(for: target, at: Date.now.addingTimeInterval(-10))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(service.getCurrentBranchPRCallCount == 0)

    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(service.getCurrentBranchPRCallCount == 1)

    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("pending checks use the faster cadence")
  func pendingChecksUseFastCadence() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(number: 7)
    service.checksResults = [
      .success([makeObservedCheck(name: "Build", status: "IN_PROGRESS", conclusion: nil, bucket: "pending")]),
      .success([makeObservedCheck(name: "Build")]),
    ]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration(pendingPollInterval: 0.02, settledPollInterval: 0.2)
    )
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")

    let subscription = await observer.subscribe(to: target)
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(70))

    #expect(service.getChecksCallCount >= 2)

    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("settled checks keep the slower cadence")
  func settledChecksUseSlowCadence() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(number: 7)
    service.checksResult = [makeObservedCheck(name: "Build")]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration(pendingPollInterval: 0.02, settledPollInterval: 0.2)
    )
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")

    let subscription = await observer.subscribe(to: target)
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(70))

    #expect(service.getChecksCallCount == 1)

    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("terminal errors pause until activity reactivates observation")
  func terminalErrorsPauseUntilActivity() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResults = [
      .failure(GitHubCLIError.notAuthenticated),
      .success(makeObservedPR(number: 9)),
    ]
    service.checksResult = [makeObservedCheck(name: "Build")]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration(pendingPollInterval: 0.02, settledPollInterval: 0.2)
    )
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")

    let subscription = await observer.subscribe(to: target)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(service.getCurrentBranchPRCallCount == 1)

    try? await Task.sleep(for: .milliseconds(40))
    #expect(service.getCurrentBranchPRCallCount == 1)

    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(service.getCurrentBranchPRCallCount == 2)

    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("unsubscribing the last subscriber cancels polling")
  func unsubscribeCancelsPolling() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(number: 7)
    service.checksResult = [
      makeObservedCheck(name: "Build", status: "IN_PROGRESS", conclusion: nil, bucket: "pending")
    ]
    let observer = GitHubPRObservationService(
      service: service,
      configuration: makeObservationConfiguration(pendingPollInterval: 0.02, settledPollInterval: 0.2)
    )
    let target = GitHubPRObservationTarget.currentBranch(projectPath: "/tmp/repo", branchName: "feature")

    let subscription = await observer.subscribe(to: target)
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(30))
    let callsBeforeUnsubscribe = service.getChecksCallCount

    await observer.unsubscribe(subscriptionID: subscription.id)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(service.getChecksCallCount == callsBeforeUnsubscribe)
  }
}
