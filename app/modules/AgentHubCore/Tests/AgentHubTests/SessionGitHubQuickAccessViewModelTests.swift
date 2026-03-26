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
