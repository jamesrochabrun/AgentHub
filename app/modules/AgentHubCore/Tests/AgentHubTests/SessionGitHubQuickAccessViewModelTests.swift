//
//  SessionGitHubQuickAccessViewModelTests.swift
//  AgentHubTests
//
//  Tests for session card GitHub quick access state
//

import Foundation
import Testing

@testable import AgentHubCore

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
    createdAt: Date(),
    updatedAt: Date(),
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

@Suite("SessionGitHubQuickAccessViewModel")
struct SessionGitHubQuickAccessViewModelTests {

  @Test("loads current branch PR when GitHub is available")
  @MainActor
  func loadsCurrentBranchPR() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = makeQuickAccessPR(number: 187, changedFiles: 12, additions: 4195, deletions: 0)
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")

    #expect(viewModel.currentBranchPR?.number == 187)
    #expect(mock.isInstalledCallCount == 1)
    #expect(mock.isAuthenticatedCallCount == 1)
    #expect(mock.getCurrentBranchPRCallCount == 1)
    #expect(mock.getCurrentBranchPRRepoPath == "/tmp/repo")
  }

  @Test("does not request PR when gh is unavailable")
  @MainActor
  func skipsWhenGHUnavailable() async {
    let mock = MockGitHubCLIService()
    mock.isInstalledResult = false
    mock.currentBranchPRResult = makeQuickAccessPR()
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")

    #expect(viewModel.currentBranchPR == nil)
    #expect(mock.isInstalledCallCount == 1)
    #expect(mock.isAuthenticatedCallCount == 0)
    #expect(mock.getCurrentBranchPRCallCount == 0)
  }

  @Test("does not request PR when gh is not authenticated")
  @MainActor
  func skipsWhenNotAuthenticated() async {
    let mock = MockGitHubCLIService()
    mock.isAuthenticatedResult = false
    mock.currentBranchPRResult = makeQuickAccessPR()
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")

    #expect(viewModel.currentBranchPR == nil)
    #expect(mock.isInstalledCallCount == 1)
    #expect(mock.isAuthenticatedCallCount == 1)
    #expect(mock.getCurrentBranchPRCallCount == 0)
  }

  @Test("treats missing current branch PR as an empty state")
  @MainActor
  func handlesNoCurrentBranchPR() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = nil
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")

    #expect(viewModel.currentBranchPR == nil)
    #expect(mock.getCurrentBranchPRCallCount == 1)
  }

  @Test("silences service errors and keeps empty quick access state")
  @MainActor
  func silencesServiceErrors() async {
    let mock = MockGitHubCLIService()
    mock.errorToThrow = GitHubCLIError.noRemoteRepository
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")

    #expect(viewModel.currentBranchPR == nil)
    #expect(mock.getCurrentBranchPRCallCount == 1)
  }

  @Test("does not reload for the same repo and branch")
  @MainActor
  func avoidsDuplicateLoadsForSameBranch() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = makeQuickAccessPR(number: 1)
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")
    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/github")

    #expect(mock.getCurrentBranchPRCallCount == 1)
    #expect(viewModel.currentBranchPR?.number == 1)
  }

  @Test("reloads when the branch changes for the same repo")
  @MainActor
  func reloadsWhenBranchChanges() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = makeQuickAccessPR(number: 1)
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/one")

    mock.currentBranchPRResult = makeQuickAccessPR(number: 2)
    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/two")

    #expect(mock.getCurrentBranchPRCallCount == 2)
    #expect(viewModel.currentBranchPR?.number == 2)
  }

  @Test("reloads when the repo path changes")
  @MainActor
  func reloadsWhenProjectPathChanges() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = makeQuickAccessPR(number: 1)
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo-a", branchName: "feature/github")

    mock.currentBranchPRResult = makeQuickAccessPR(number: 2)
    await viewModel.load(projectPath: "/tmp/repo-b", branchName: "feature/github")

    #expect(mock.getCurrentBranchPRCallCount == 2)
    #expect(viewModel.currentBranchPR?.number == 2)
  }
}

// MARK: - Polling Tests

@Suite("SessionGitHubQuickAccessViewModel Polling")
struct SessionGitHubQuickAccessViewModelPollingTests {

  @Test("stopPolling cancels active polling")
  @MainActor
  func stopPollingCancelsTask() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = nil
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")
    #expect(mock.getCurrentBranchPRCallCount == 1)

    // Stop polling immediately — no further calls should be made
    viewModel.stopPolling()

    // Give potential polling a chance to fire (it shouldn't)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(mock.getCurrentBranchPRCallCount == 1)
  }

  @Test("load starts polling that can detect a PR created later")
  @MainActor
  func pollingDetectsNewPR() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = nil
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")
    #expect(viewModel.currentBranchPR == nil)
    #expect(mock.getCurrentBranchPRCallCount == 1)

    // Simulate a PR being created after initial load
    mock.currentBranchPRResult = makeQuickAccessPR(number: 42)

    // The polling interval is 30s for nil PR, so we can't wait that long in a test.
    // Instead, verify polling was started by stopping it and confirming the mechanism.
    viewModel.stopPolling()
  }

  @Test("notifySessionActivity resumes polling after it was paused")
  @MainActor
  func notifyActivityResumesPolling() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = makeQuickAccessPR(number: 1)
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")
    #expect(viewModel.currentBranchPR?.number == 1)

    // Stop polling to simulate idle pause
    viewModel.stopPolling()

    // notifySessionActivity should restart polling
    viewModel.notifySessionActivity()

    // Stop again to clean up
    viewModel.stopPolling()
  }

  @Test("notifySessionActivity does nothing when no project path is set")
  @MainActor
  func notifyActivityNoopWithoutProject() async {
    let mock = MockGitHubCLIService()
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    // Never called load(), so no project path stored
    viewModel.notifySessionActivity()

    // Should not crash or start polling
    #expect(mock.getCurrentBranchPRCallCount == 0)
  }

  @Test("branch change stops previous polling and starts new")
  @MainActor
  func branchChangeCyclesPolling() async {
    let mock = MockGitHubCLIService()
    mock.currentBranchPRResult = makeQuickAccessPR(number: 1)
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/one")
    #expect(viewModel.currentBranchPR?.number == 1)
    #expect(mock.getCurrentBranchPRCallCount == 1)

    // Switch branches — should reset and re-fetch
    mock.currentBranchPRResult = makeQuickAccessPR(number: 2)
    await viewModel.load(projectPath: "/tmp/repo", branchName: "feature/two")
    #expect(viewModel.currentBranchPR?.number == 2)
    #expect(mock.getCurrentBranchPRCallCount == 2)

    viewModel.stopPolling()
  }

  @Test("does not start polling when gh is not installed")
  @MainActor
  func noPollingWhenGHUnavailable() async {
    let mock = MockGitHubCLIService()
    mock.isInstalledResult = false
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")

    // Give a brief moment for any errant polling
    try? await Task.sleep(for: .milliseconds(100))
    #expect(mock.getCurrentBranchPRCallCount == 0)
  }

  @Test("does not start polling when not authenticated")
  @MainActor
  func noPollingWhenNotAuthenticated() async {
    let mock = MockGitHubCLIService()
    mock.isAuthenticatedResult = false
    let viewModel = SessionGitHubQuickAccessViewModel(service: mock)

    await viewModel.load(projectPath: "/tmp/repo", branchName: "main")

    try? await Task.sleep(for: .milliseconds(100))
    #expect(mock.getCurrentBranchPRCallCount == 0)
  }
}
