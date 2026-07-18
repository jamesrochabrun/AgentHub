//
//  GitHubPRObservationServiceTests.swift
//  AgentHubTests
//
//  Tests for shared GitHub PR/check observation.
//

import Foundation
import Testing

@testable import AgentHubGitHub

private func makeObservedPR(
  number: Int = 1,
  title: String = "Observed PR",
  state: String = "OPEN",
  headRefOid: String? = nil,
  checks: [GitHubCheckRun]? = nil,
  reviewDecision: String? = nil,
  mergeable: String? = "MERGEABLE"
) -> GitHubPullRequest {
  GitHubPullRequest(
    number: number,
    title: title,
    body: nil,
    state: state,
    url: "https://github.com/test/repo/pull/\(number)",
    headRefName: "feature",
    headRefOid: headRefOid,
    baseRefName: "main",
    author: GitHubAuthor(login: "testuser", name: nil),
    createdAt: .now,
    updatedAt: .now,
    isDraft: false,
    mergeable: mergeable,
    additions: 10,
    deletions: 2,
    changedFiles: 3,
    reviewDecision: reviewDecision,
    statusCheckRollup: checks,
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

private actor FixedGitHubRepositoryIdentityResolver: GitHubRepositoryIdentityResolverProtocol {
  let identity: GitHubRepositoryIdentity?

  init(identity: GitHubRepositoryIdentity?) {
    self.identity = identity
  }

  func resolveIdentity(at projectPath: String) async -> GitHubRepositoryIdentity? {
    identity
  }
}

@Suite("GitHubPRObservationService")
struct GitHubPRObservationServiceTests {

  @Test("uses the exact session branch and embedded check rollup in one fetch")
  func usesExactBranchAndEmbeddedChecks() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(
      number: 5,
      headRefOid: "abc123",
      checks: [makeObservedCheck(name: "Build", conclusion: "FAILURE")]
    )
    let observer = GitHubPRObservationService(
      service: service,
      repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: nil),
      configuration: makeObservationConfiguration()
    )
    let target = GitHubPRObservationTarget.currentBranch(
      projectPath: "/tmp/repo",
      branchName: "feature/exact"
    )

    await observer.refresh(target)

    #expect(service.getCurrentBranchPRCallCount == 1)
    #expect(service.getCurrentBranchPRBranchName == "feature/exact")
    #expect(service.getChecksCallCount == 0)
  }

  @Test("uses only linked pull requests that match the session repository")
  func verifiesLinkedPullRequestRepository() async throws {
    let service = MockGitHubCLIService()
    service.pullRequestResult = makeObservedPR(number: 41, checks: [])
    service.currentBranchPRResult = makeObservedPR(number: 42, checks: [])
    let identity = GitHubRepositoryIdentity(owner: "test", repository: "repo")
    let observer = GitHubPRObservationService(
      service: service,
      repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: identity),
      configuration: makeObservationConfiguration()
    )
    let unrelated = try #require(GitHubPullRequestURLReference(
      urlString: "https://github.com/other/project/pull/40"
    ))
    let matching = try #require(GitHubPullRequestURLReference(
      urlString: "https://github.com/test/repo/pull/41"
    ))
    let linkedTarget = GitHubPRObservationTarget.session(
      projectPath: "/tmp/repo",
      branchName: "feature/exact",
      linkedPullRequests: [unrelated, matching]
    )

    await observer.refresh(linkedTarget)

    #expect(service.getPullRequestCallCount == 1)
    #expect(service.getPullRequestNumber == 41)
    #expect(service.getCurrentBranchPRCallCount == 0)

    let branchTarget = GitHubPRObservationTarget.session(
      projectPath: "/tmp/other-copy",
      branchName: "feature/fallback",
      linkedPullRequests: [unrelated]
    )
    await observer.refresh(branchTarget)

    #expect(service.getCurrentBranchPRCallCount == 1)
    #expect(service.getCurrentBranchPRBranchName == "feature/fallback")
  }

  @Test("preserves same-head checks and freshness when a fallback check fetch fails")
  func preservesSameHeadChecksOnTransientFailure() async {
    let service = MockGitHubCLIService()
    let pullRequest = makeObservedPR(number: 51, headRefOid: "same-head", checks: nil)
    service.currentBranchPRResults = [.success(pullRequest), .success(pullRequest)]
    service.checksResults = [
      .success([makeObservedCheck(name: "Build", conclusion: "FAILURE")]),
      .failure(GitHubCLIError.timeout),
    ]
    let observer = GitHubPRObservationService(
      service: service,
      repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: nil),
      configuration: makeObservationConfiguration()
    )
    let target = GitHubPRObservationTarget.currentBranch(
      projectPath: "/tmp/repo",
      branchName: "feature"
    )
    let collector = ObservationSnapshotCollector()
    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)
    let collectionTask = Task {
      for await snapshot in subscription.updates {
        await collector.append(snapshot)
      }
    }

    await observer.refresh(target)
    try? await Task.sleep(for: .milliseconds(5))
    let successfulRefreshDate = await collector.snapshots().last {
      $0.state == .ready
    }?.lastRefreshedAt
    await observer.refresh(target)
    try? await Task.sleep(for: .milliseconds(5))

    let degraded = await collector.snapshots().last
    #expect(degraded?.checks.map(\.name) == ["Build"])
    #expect(degraded?.ciSummary.overallStatus == .failure)
    #expect(degraded?.lastRefreshedAt == successfulRefreshDate)
    #expect(degraded?.isStale == true)

    collectionTask.cancel()
    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("does not carry fallback checks across pull request head commits")
  func clearsFallbackChecksForNewHead() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResults = [
      .success(makeObservedPR(number: 52, headRefOid: "old-head", checks: nil)),
      .success(makeObservedPR(number: 52, headRefOid: "new-head", checks: nil)),
    ]
    service.checksResults = [
      .success([makeObservedCheck(name: "Old build", conclusion: "FAILURE")]),
      .failure(GitHubCLIError.timeout),
    ]
    let observer = GitHubPRObservationService(
      service: service,
      repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: nil),
      configuration: makeObservationConfiguration(errorBackoff: [1])
    )
    let target = GitHubPRObservationTarget.currentBranch(
      projectPath: "/tmp/repo",
      branchName: "feature"
    )
    let collector = ObservationSnapshotCollector()
    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)
    let collectionTask = Task {
      for await snapshot in subscription.updates {
        await collector.append(snapshot)
      }
    }

    await observer.refresh(target)
    await observer.refresh(target)
    try? await Task.sleep(for: .milliseconds(5))

    let degraded = await collector.snapshots().last
    #expect(degraded?.pullRequest?.headRefOid == "new-head")
    #expect(degraded?.checks.isEmpty == true)
    #expect(degraded?.lastRefreshedAt == nil)
    #expect(degraded?.isStale == false)

    collectionTask.cancel()
    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test(
    "continues pending checks after idle and stops at the pending deadline",
    .disabled("headless-quarantine: wall-clock cadence timing — flaky on CI; see TestQuarantine.md")
  )
  func pendingChecksOutliveIdleButRespectDeadline() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(
      number: 61,
      headRefOid: "pending-head",
      checks: [makeObservedCheck(
        name: "Build",
        status: "WAITING",
        conclusion: nil
      )]
    )
    let observer = GitHubPRObservationService(
      service: service,
      repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: nil),
      configuration: GitHubPRObservationConfiguration(
        pendingPollInterval: 0.01,
        idlePendingPollInterval: 0.02,
        settledPollInterval: 0.2,
        idleTimeout: 0.005,
        checksDiscoveryWindow: 0.05,
        pendingObservationLimit: 0.07,
        inactiveEntryRetention: 1,
        maximumConcurrentRefreshes: 2,
        errorBackoff: [0.02]
      )
    )
    let target = GitHubPRObservationTarget.currentBranch(
      projectPath: "/tmp/repo",
      branchName: "feature"
    )
    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)

    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(40))
    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(60))
    let callsAtDeadline = service.getCurrentBranchPRCallCount
    try? await Task.sleep(for: .milliseconds(60))

    #expect(callsAtDeadline >= 3)
    #expect(service.getCurrentBranchPRCallCount == callsAtDeadline)

    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test(
    "bounds pull request discovery after session activity",
    .disabled("headless-quarantine: wall-clock cadence timing — flaky on CI; see TestQuarantine.md")
  )
  func boundsPullRequestDiscovery() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = nil
    let observer = GitHubPRObservationService(
      service: service,
      repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: nil),
      configuration: GitHubPRObservationConfiguration(
        pendingPollInterval: 0.01,
        idlePendingPollInterval: 0.02,
        settledPollInterval: 0.2,
        idleTimeout: 0.005,
        checksDiscoveryWindow: 0.06,
        pendingObservationLimit: 1,
        inactiveEntryRetention: 1,
        maximumConcurrentRefreshes: 2,
        errorBackoff: [0.02]
      )
    )
    let target = GitHubPRObservationTarget.currentBranch(
      projectPath: "/tmp/repo",
      branchName: "feature"
    )
    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)

    await observer.recordActivity(for: target, at: .now)
    try? await Task.sleep(for: .milliseconds(90))
    let callsAfterDiscovery = service.getCurrentBranchPRCallCount
    try? await Task.sleep(for: .milliseconds(50))

    #expect(callsAfterDiscovery >= 2)
    #expect(service.getCurrentBranchPRCallCount == callsAfterDiscovery)

    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("manual refresh populates cache without a subscriber")
  func manualRefreshWithoutSubscriberPopulatesCache() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRResult = makeObservedPR(number: 71, checks: [])
    let observer = GitHubPRObservationService(
      service: service,
      repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: nil),
      configuration: makeObservationConfiguration()
    )
    let target = GitHubPRObservationTarget.currentBranch(
      projectPath: "/tmp/repo",
      branchName: "feature"
    )

    await observer.refresh(target)
    let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)
    var iterator = subscription.updates.makeAsyncIterator()
    let cachedSnapshot = await iterator.next()

    #expect(cachedSnapshot?.pullRequest?.number == 71)
    #expect(cachedSnapshot?.state == .ready)
    #expect(service.getCurrentBranchPRCallCount == 1)

    await observer.unsubscribe(subscriptionID: subscription.id)
  }

  @Test("terminal pull requests stop automatic observation but remain manually refreshable")
  func terminalPullRequestsStopAutomaticObservation() async {
    for state in ["MERGED", "CLOSED"] {
      let service = MockGitHubCLIService()
      service.currentBranchPRResult = makeObservedPR(
        number: 73,
        state: state,
        headRefOid: "terminal-head",
        checks: []
      )
      let observer = GitHubPRObservationService(
        service: service,
        repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: nil),
        configuration: GitHubPRObservationConfiguration(
          pendingPollInterval: 0.01,
          idlePendingPollInterval: 0.01,
          settledPollInterval: 0.01,
          idleTimeout: 1,
          checksDiscoveryWindow: 1,
          pendingObservationLimit: 1,
          inactiveEntryRetention: 1,
          maximumConcurrentRefreshes: 2,
          errorBackoff: [0.01]
        )
      )
      let target = GitHubPRObservationTarget.currentBranch(
        projectPath: "/tmp/repo-\(state.lowercased())",
        branchName: "feature"
      )
      let subscription = await observer.subscribe(to: target, refreshOnSubscribe: false)

      await observer.recordActivity(for: target, at: .now)
      try? await Task.sleep(for: .milliseconds(50))

      #expect(service.getCurrentBranchPRCallCount == 1)

      await observer.recordActivity(for: target, at: .now)
      try? await Task.sleep(for: .milliseconds(30))

      #expect(service.getCurrentBranchPRCallCount == 1)

      await observer.refresh(target)
      try? await Task.sleep(for: .milliseconds(30))

      #expect(service.getCurrentBranchPRCallCount == 2)

      await observer.unsubscribe(subscriptionID: subscription.id)
    }
  }

  @Test("caps concurrent refresh work across targets")
  func capsConcurrentRefreshes() async {
    let service = MockGitHubCLIService()
    service.currentBranchPRDelay = 0.04
    service.currentBranchPRResult = makeObservedPR(number: 72, checks: [])
    let observer = GitHubPRObservationService(
      service: service,
      repositoryIdentityResolver: FixedGitHubRepositoryIdentityResolver(identity: nil),
      configuration: GitHubPRObservationConfiguration(
        maximumConcurrentRefreshes: 2
      )
    )
    let targets = (0..<4).map { index in
      GitHubPRObservationTarget.currentBranch(
        projectPath: "/tmp/repo-\(index)",
        branchName: "feature-\(index)"
      )
    }

    await withTaskGroup(of: Void.self) { group in
      for target in targets {
        group.addTask {
          await observer.refresh(target)
        }
      }
    }

    #expect(await service.peakCurrentBranchPRCallCount() == 2)
  }

  @Test("derives CI, review, and merge blockers without extra fetches")
  func derivesAllBlockers() {
    let pullRequest = makeObservedPR(
      number: 81,
      checks: [makeObservedCheck(name: "Build", conclusion: "FAILURE")],
      reviewDecision: "CHANGES_REQUESTED",
      mergeable: "CONFLICTING"
    )
    let snapshot = GitHubPRObservationSnapshot(
      target: .pullRequest(projectPath: "/tmp/repo", number: 81),
      pullRequest: pullRequest,
      checks: pullRequest.statusCheckRollup ?? [],
      state: .ready,
      lastRefreshedAt: .now
    )

    #expect(snapshot.blockers == [.ciFailure, .changesRequested, .mergeConflict])
  }

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
    #expect(service.getCurrentBranchPRCallCount >= 1)
    #expect(service.getChecksCallCount >= 1)

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
    #expect(service.getCurrentBranchPRCallCount >= 1)
    #expect(service.getChecksCallCount >= 1)

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
      configuration: makeObservationConfiguration(errorBackoff: [0.2])
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
