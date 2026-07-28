//
//  GitHubCIFailureNotifierTests.swift
//  AgentHubTests
//
//  Tests for CI failure notification dedupe, gating, payload, and routing
//

import AgentHubGitHub
import Foundation
import Testing
import UserNotifications

@testable import AgentHubCore

// MARK: - Fixtures

private func makeCIFailurePR(
  number: Int = 10,
  title: String = "Fix everything",
  state: String = "OPEN",
  headRefOid: String? = "abc123"
) -> GitHubPullRequest {
  GitHubPullRequest(
    number: number,
    title: title,
    body: nil,
    state: state,
    url: "https://github.com/test/repo/pull/\(number)",
    headRefName: "feature-branch",
    headRefOid: headRefOid,
    baseRefName: "main",
    author: nil,
    createdAt: .now,
    updatedAt: .now,
    isDraft: false,
    mergeable: "MERGEABLE",
    additions: 1,
    deletions: 1,
    changedFiles: 1,
    reviewDecision: nil,
    statusCheckRollup: nil,
    labels: nil,
    reviewRequests: nil,
    comments: nil
  )
}

private func makeCIFailureSnapshot(
  pullRequest: GitHubPullRequest? = makeCIFailurePR(),
  checks: [GitHubCheckRun] = [
    GitHubCheckRun(
      name: "test",
      status: "COMPLETED",
      conclusion: "FAILURE",
      detailsUrl: "https://github.com/test/repo/actions/runs/99/job/1",
      workflowName: "Tests"
    )
  ],
  state: GitHubPRObservationState = .ready
) -> GitHubPRObservationSnapshot {
  GitHubPRObservationSnapshot(
    target: .currentBranch(projectPath: "/tmp/repo", branchName: "feature-branch"),
    pullRequest: pullRequest,
    checks: checks,
    state: state,
    lastRefreshedAt: .now
  )
}

private func makeCIFailureContext(sessionId: String = "session-1") -> GitHubCIFailureSessionContext {
  GitHubCIFailureSessionContext(
    sessionId: sessionId,
    providerKind: .claude,
    projectPath: "/tmp/repo",
    branchName: "feature-branch"
  )
}

private actor NotificationRequestRecorder {
  private(set) var requests: [UNNotificationRequest] = []

  func record(_ request: UNNotificationRequest) {
    requests.append(request)
  }
}

// MARK: - GitHubCIFailureNotifier

@Suite("GitHubCIFailureNotifier")
struct GitHubCIFailureNotifierTests {

  @MainActor
  private func makeNotifier(
    enabled: Bool = true,
    recorder: NotificationRequestRecorder
  ) -> GitHubCIFailureNotifier {
    GitHubCIFailureNotifier(
      isEnabled: { enabled },
      sendNotification: { await recorder.record($0) }
    )
  }

  @Test("posts one notification with Fix CI category and routable payload")
  @MainActor
  func postsNotificationForFailingCI() async {
    let recorder = NotificationRequestRecorder()
    let notifier = makeNotifier(recorder: recorder)

    notifier.evaluate(snapshot: makeCIFailureSnapshot(), context: makeCIFailureContext())
    try? await Task.sleep(for: .milliseconds(50))

    let requests = await recorder.requests
    #expect(requests.count == 1)
    let content = requests.first?.content
    #expect(content?.categoryIdentifier == GitHubCIFailureNotification.categoryIdentifier)
    #expect(content?.title == "CI failing on PR #10")
    #expect(content?.subtitle == "repo")
    #expect(content?.body == "test failed")

    let payload = content.flatMap { GitHubCIFailureNotificationPayload(userInfo: $0.userInfo) }
    #expect(payload?.sessionId == "session-1")
    #expect(payload?.providerKind == .claude)
    #expect(payload?.projectPath == "/tmp/repo")
    #expect(payload?.prNumber == 10)
    #expect(payload?.failedChecks.first?.detailsUrl == "https://github.com/test/repo/actions/runs/99/job/1")
  }

  @Test("deduplicates repeat snapshots for the same PR head commit")
  @MainActor
  func deduplicatesSameHead() async {
    let recorder = NotificationRequestRecorder()
    let notifier = makeNotifier(recorder: recorder)

    notifier.evaluate(snapshot: makeCIFailureSnapshot(), context: makeCIFailureContext())
    notifier.evaluate(snapshot: makeCIFailureSnapshot(), context: makeCIFailureContext(sessionId: "other-surface"))
    try? await Task.sleep(for: .milliseconds(50))

    #expect(await recorder.requests.count == 1)
  }

  @Test("notifies again when the PR head commit changes")
  @MainActor
  func notifiesAgainForNewHead() async {
    let recorder = NotificationRequestRecorder()
    let notifier = makeNotifier(recorder: recorder)

    notifier.evaluate(snapshot: makeCIFailureSnapshot(), context: makeCIFailureContext())
    notifier.evaluate(
      snapshot: makeCIFailureSnapshot(pullRequest: makeCIFailurePR(headRefOid: "def456")),
      context: makeCIFailureContext()
    )
    try? await Task.sleep(for: .milliseconds(50))

    #expect(await recorder.requests.count == 2)
  }

  @Test("ignores passing, refreshing, closed-PR, and disabled evaluations")
  @MainActor
  func ignoresNonActionableSnapshots() async {
    let recorder = NotificationRequestRecorder()
    let notifier = makeNotifier(recorder: recorder)

    let passingChecks = [GitHubCheckRun(name: "test", status: "COMPLETED", conclusion: "SUCCESS")]
    notifier.evaluate(snapshot: makeCIFailureSnapshot(checks: passingChecks), context: makeCIFailureContext())
    notifier.evaluate(snapshot: makeCIFailureSnapshot(state: .refreshing), context: makeCIFailureContext())
    notifier.evaluate(snapshot: makeCIFailureSnapshot(state: .error("boom")), context: makeCIFailureContext())
    notifier.evaluate(
      snapshot: makeCIFailureSnapshot(pullRequest: makeCIFailurePR(state: "MERGED")),
      context: makeCIFailureContext()
    )
    notifier.evaluate(snapshot: makeCIFailureSnapshot(pullRequest: nil), context: makeCIFailureContext())

    let disabledNotifier = makeNotifier(enabled: false, recorder: recorder)
    disabledNotifier.evaluate(snapshot: makeCIFailureSnapshot(), context: makeCIFailureContext())
    try? await Task.sleep(for: .milliseconds(50))

    #expect(await recorder.requests.isEmpty)
  }

  @Test("body summarizes many failed checks")
  func bodySummarizesManyChecks() {
    #expect(GitHubCIFailureNotifier.body(failedCheckNames: ["a"]) == "a failed")
    #expect(GitHubCIFailureNotifier.body(failedCheckNames: ["a", "b", "c"]) == "a, b, c failed")
    #expect(GitHubCIFailureNotifier.body(failedCheckNames: ["a", "b", "c", "d", "e"]) == "a, b, c and 2 more failed")
  }
}

// MARK: - Payload round-trip

@Suite("GitHubCIFailureNotificationPayload")
struct GitHubCIFailureNotificationPayloadTests {

  @Test("round-trips through notification userInfo")
  func roundTripsThroughUserInfo() {
    let payload = GitHubCIFailureNotificationPayload(
      sessionId: "abc",
      providerKindRawValue: "Codex",
      projectPath: "/tmp/repo",
      branchName: "feature",
      prNumber: 7,
      prTitle: "Title",
      failedChecks: [.init(name: "test", workflowName: "CI", detailsUrl: "https://example.com")]
    )

    let decoded = GitHubCIFailureNotificationPayload(userInfo: payload.userInfo)
    #expect(decoded == payload)
    #expect(decoded?.providerKind == .codex)
    #expect(payload.userInfo["sessionId"] as? String == "abc")
  }

  @Test("returns nil for foreign userInfo")
  func rejectsForeignUserInfo() {
    #expect(GitHubCIFailureNotificationPayload(userInfo: ["sessionId": "abc"]) == nil)
    #expect(GitHubCIFailureNotificationPayload(userInfo: [:]) == nil)
  }
}

// MARK: - Action router

@Suite("GitHubCIFailureActionRouter")
@MainActor
struct GitHubCIFailureActionRouterTests {

  @Test("publishes requests and consumes only matching ids")
  func publishesAndConsumes() {
    let router = GitHubCIFailureActionRouter()
    let payload = GitHubCIFailureNotificationPayload(
      sessionId: "abc",
      providerKindRawValue: "Claude",
      projectPath: "/tmp/repo",
      branchName: "feature",
      prNumber: 1,
      prTitle: "Title",
      failedChecks: []
    )

    router.request(payload: payload, action: .fixCI)
    let first = router.pendingRequest
    #expect(first?.action == .fixCI)
    #expect(first?.payload == payload)

    router.request(payload: payload, action: .openGitHubPanel)
    let second = router.pendingRequest
    #expect(second?.action == .openGitHubPanel)

    if let first {
      router.markConsumed(first)
      #expect(router.pendingRequest?.id == second?.id)
    }
    if let second {
      router.markConsumed(second)
      #expect(router.pendingRequest == nil)
    }
  }
}
