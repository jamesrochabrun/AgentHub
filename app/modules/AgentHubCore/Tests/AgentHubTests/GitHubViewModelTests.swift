//
//  GitHubViewModelTests.swift
//  AgentHubTests
//
//  Tests for GitHubViewModel using MockGitHubCLIService
//

import Foundation
import Testing

@testable import AgentHubCore

// MARK: - Test Fixtures

private func makePR(
  number: Int = 1,
  title: String = "Test PR",
  state: String = "OPEN",
  isDraft: Bool = false,
  additions: Int = 10,
  deletions: Int = 5,
  changedFiles: Int = 3
) -> GitHubPullRequest {
  GitHubPullRequest(
    number: number,
    title: title,
    body: "Test body",
    state: state,
    url: "https://github.com/test/repo/pull/\(number)",
    headRefName: "feature-branch",
    baseRefName: "main",
    author: GitHubAuthor(login: "testuser", name: "Test User"),
    createdAt: Date(),
    updatedAt: Date(),
    isDraft: isDraft,
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

private func makeIssue(
  number: Int = 1,
  title: String = "Test Issue",
  state: String = "OPEN"
) -> GitHubIssue {
  GitHubIssue(
    number: number,
    title: title,
    body: "Issue body",
    state: state,
    url: "https://github.com/test/repo/issues/\(number)",
    author: GitHubAuthor(login: "testuser", name: "Test User"),
    createdAt: Date(),
    updatedAt: Date(),
    labels: nil,
    assignees: nil,
    comments: nil
  )
}

private func makeRepoInfo() -> GitHubRepoInfo {
  GitHubRepoInfo(
    owner: "testowner",
    name: "testrepo",
    fullName: "testowner/testrepo",
    defaultBranch: "main",
    isPrivate: false,
    url: "https://github.com/testowner/testrepo"
  )
}

private func makeCheck(
  name: String = "CI",
  status: String = "COMPLETED",
  conclusion: String? = "SUCCESS"
) -> GitHubCheckRun {
  GitHubCheckRun(
    name: name,
    status: status,
    conclusion: conclusion,
    detailsUrl: nil
  )
}

// MARK: - Setup Tests

@Suite("GitHubViewModel Setup")
struct GitHubViewModelSetupTests {

  @Test("setup detects gh installation and authentication")
  @MainActor
  func setupDetectsInstallAndAuth() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)

    await vm.setup(repoPath: "/tmp/repo")

    #expect(vm.isGHInstalled == true)
    #expect(vm.isAuthenticated == true)
    #expect(vm.repoInfo?.fullName == "testowner/testrepo")
    #expect(mock.getRepoInfoCalled == true)
  }

  @Test("setup reports gh not installed")
  @MainActor
  func setupReportsNotInstalled() async {
    let mock = MockGitHubCLIService()
    mock.isInstalledResult = false
    let vm = GitHubViewModel(service: mock)

    await vm.setup(repoPath: "/tmp/repo")

    #expect(vm.isGHInstalled == false)
    #expect(vm.isAuthenticated == false)
    #expect(vm.repoInfo == nil)
  }

  @Test("setup reports not authenticated")
  @MainActor
  func setupReportsNotAuthenticated() async {
    let mock = MockGitHubCLIService()
    mock.isAuthenticatedResult = false
    let vm = GitHubViewModel(service: mock)

    await vm.setup(repoPath: "/tmp/repo")

    #expect(vm.isGHInstalled == true)
    #expect(vm.isAuthenticated == false)
    #expect(vm.repoInfo == nil)
  }
}

// MARK: - Pull Request Tests

@Suite("GitHubViewModel Pull Requests")
struct GitHubViewModelPRTests {

  @Test("loadPullRequests populates list on success")
  @MainActor
  func loadPullRequestsSuccess() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.pullRequestsResult = [makePR(number: 1), makePR(number: 2)]
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    await vm.loadPullRequests()

    #expect(vm.pullRequests.count == 2)
    #expect(vm.prLoadingState == .loaded)
    #expect(mock.listPullRequestsCalled == true)
    #expect(mock.listPullRequestsState == "open")
    #expect(mock.listPullRequestsLimit == 30)
  }

  @Test("loadPullRequests sets error state on failure")
  @MainActor
  func loadPullRequestsError() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    mock.errorToThrow = GitHubCLIError.commandFailed("network error")
    await vm.loadPullRequests()

    #expect(vm.pullRequests.isEmpty)
    #expect(vm.prLoadingState == .error("GitHub CLI command failed: network error"))
  }

  @Test("loadPRDetail loads PR, diff, and comments in parallel")
  @MainActor
  func loadPRDetailSuccess() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.pullRequestResult = makePR(number: 42)
    mock.pullRequestDiffResult = "diff --git a/file.swift b/file.swift\n+hello"
    mock.reviewCommentsResult = [
      GitHubComment(id: "1", author: nil, body: "Nice!", createdAt: nil, path: "file.swift", line: 1, diffHunk: nil)
    ]
    mock.pullRequestFilesResult = [
      GitHubPRFile(filename: "file.swift", status: "modified", additions: 5, deletions: 2, patch: "+hello")
    ]
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    await vm.loadPRDetail(number: 42)

    #expect(vm.selectedPR?.number == 42)
    #expect(vm.selectedPRDiff.contains("+hello"))
    #expect(vm.selectedPRReviewComments.count == 1)
    #expect(vm.selectedPRFiles.count == 1)
    #expect(vm.prDetailLoadingState == .loaded)
    #expect(mock.getPullRequestCalled == true)
    #expect(mock.getPullRequestDiffCalled == true)
    #expect(mock.getPullRequestReviewCommentsCalled == true)
    #expect(mock.getPullRequestFilesCalled == true)
  }

  @Test("loadCurrentBranchPR stores PR when found")
  @MainActor
  func loadCurrentBranchPR() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.currentBranchPRResult = makePR(number: 7, title: "My Branch PR")
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    await vm.loadCurrentBranchPR()

    #expect(vm.currentBranchPR?.number == 7)
    #expect(mock.getCurrentBranchPRCalled == true)
  }

  @Test("loadCurrentBranchPR nil when no PR exists")
  @MainActor
  func loadCurrentBranchPRNone() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.currentBranchPRResult = nil
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    await vm.loadCurrentBranchPR()

    #expect(vm.currentBranchPR == nil)
  }

  @Test("submitPRComment calls service and clears input")
  @MainActor
  func submitPRComment() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.pullRequestResult = makePR(number: 5)
    mock.pullRequestDiffResult = ""
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    // Select a PR first
    vm.selectedPR = makePR(number: 5)
    vm.newCommentText = "Looks good!"

    await vm.submitPRComment()

    #expect(mock.addPRCommentCalled == true)
    #expect(mock.addPRCommentPRNumber == 5)
    #expect(mock.addPRCommentBody == "Looks good!")
    #expect(vm.newCommentText == "")
  }

  @Test("submitPRComment does nothing when text is empty")
  @MainActor
  func submitPRCommentEmpty() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")
    vm.selectedPR = makePR(number: 5)
    vm.newCommentText = ""

    await vm.submitPRComment()

    #expect(mock.addPRCommentCalled == false)
  }

  @Test("submitReview calls service with correct event")
  @MainActor
  func submitReview() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.pullRequestResult = makePR(number: 10)
    mock.pullRequestDiffResult = ""
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")
    vm.selectedPR = makePR(number: 10)
    vm.reviewBody = "LGTM"

    await vm.submitReview(event: .approve)

    #expect(mock.submitReviewCalled == true)
    #expect(mock.submitReviewPRNumber == 10)
    #expect(mock.submitReviewInput?.event == .approve)
    #expect(mock.submitReviewInput?.body == "LGTM")
    #expect(vm.reviewBody == "")
  }

  @Test("checkoutPR calls service")
  @MainActor
  func checkoutPR() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")
    vm.selectedPR = makePR(number: 3)

    await vm.checkoutPR()

    #expect(mock.checkoutPRCalled == true)
    #expect(mock.checkoutPRNumber == 3)
  }
}

// MARK: - Issue Tests

@Suite("GitHubViewModel Issues")
struct GitHubViewModelIssueTests {

  @Test("loadIssues populates list on success")
  @MainActor
  func loadIssuesSuccess() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.issuesResult = [makeIssue(number: 1), makeIssue(number: 2), makeIssue(number: 3)]
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    await vm.loadIssues()

    #expect(vm.issues.count == 3)
    #expect(vm.issueLoadingState == .loaded)
    #expect(mock.listIssuesCalled == true)
  }

  @Test("loadIssues sets error state on failure")
  @MainActor
  func loadIssuesError() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    mock.errorToThrow = GitHubCLIError.noRemoteRepository
    await vm.loadIssues()

    #expect(vm.issues.isEmpty)
    #expect(vm.issueLoadingState == .error("No GitHub remote found for this repository"))
  }

  @Test("loadIssueDetail loads issue details")
  @MainActor
  func loadIssueDetail() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.issueResult = makeIssue(number: 42, title: "Bug report")
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    await vm.loadIssueDetail(number: 42)

    #expect(vm.selectedIssue?.number == 42)
    #expect(vm.selectedIssue?.title == "Bug report")
    #expect(vm.issueDetailLoadingState == .loaded)
    #expect(mock.getIssueCalled == true)
    #expect(mock.getIssueNumber == 42)
  }

  @Test("submitIssueComment calls service and clears input")
  @MainActor
  func submitIssueComment() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.issueResult = makeIssue(number: 8)
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")
    vm.selectedIssue = makeIssue(number: 8)
    vm.newCommentText = "I can reproduce this"

    await vm.submitIssueComment()

    #expect(mock.addIssueCommentCalled == true)
    #expect(mock.addIssueCommentNumber == 8)
    #expect(mock.addIssueCommentBody == "I can reproduce this")
    #expect(vm.newCommentText == "")
  }
}

// MARK: - CI Checks Tests

@Suite("GitHubViewModel CI Checks")
struct GitHubViewModelChecksTests {

  @Test("loadChecks populates check list")
  @MainActor
  func loadChecksSuccess() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.checksResult = [
      makeCheck(name: "Build", conclusion: "SUCCESS"),
      makeCheck(name: "Tests", conclusion: "FAILURE"),
    ]
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    await vm.loadChecks(prNumber: 5)

    #expect(vm.checks.count == 2)
    #expect(vm.checksLoadingState == .loaded)
    #expect(mock.getChecksCalled == true)
    #expect(mock.getChecksPRNumber == 5)
  }

  @Test("loadChecks sets error state on failure")
  @MainActor
  func loadChecksError() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    mock.errorToThrow = GitHubCLIError.timeout
    await vm.loadChecks()

    #expect(vm.checks.isEmpty)
    #expect(vm.checksLoadingState == .error("GitHub CLI command timed out"))
  }
}

// MARK: - Navigation Tests

@Suite("GitHubViewModel Navigation")
struct GitHubViewModelNavigationTests {

  @Test("selectPR sets selectedPR and clears detail state")
  @MainActor
  func selectPR() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.pullRequestResult = makePR(number: 1)
    mock.pullRequestDiffResult = ""
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    let pr = makePR(number: 1, title: "Selected")
    vm.selectPR(pr)

    #expect(vm.selectedPR?.number == 1)
    #expect(vm.selectedPRFiles.isEmpty)
    #expect(vm.selectedPRDiff == "")
    #expect(vm.selectedPRReviewComments.isEmpty)
  }

  @Test("deselectPR clears all PR detail state")
  @MainActor
  func deselectPR() async {
    let mock = MockGitHubCLIService()
    let vm = GitHubViewModel(service: mock)

    vm.selectedPR = makePR(number: 1)
    vm.selectedPRDiff = "some diff"
    vm.selectedPRFiles = [GitHubPRFile(filename: "a.swift", status: "modified", additions: 1, deletions: 0, patch: nil)]

    vm.deselectPR()

    #expect(vm.selectedPR == nil)
    #expect(vm.selectedPRFiles.isEmpty)
    #expect(vm.selectedPRDiff == "")
    #expect(vm.selectedPRReviewComments.isEmpty)
    #expect(vm.prDetailLoadingState == .idle)
  }

  @Test("selectIssue sets selectedIssue")
  @MainActor
  func selectIssue() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    mock.issueResult = makeIssue(number: 5)
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    let issue = makeIssue(number: 5, title: "Bug")
    vm.selectIssue(issue)

    #expect(vm.selectedIssue?.number == 5)
  }

  @Test("deselectIssue clears issue state")
  @MainActor
  func deselectIssue() async {
    let mock = MockGitHubCLIService()
    let vm = GitHubViewModel(service: mock)

    vm.selectedIssue = makeIssue(number: 5)
    vm.deselectIssue()

    #expect(vm.selectedIssue == nil)
    #expect(vm.issueDetailLoadingState == .idle)
  }
}

// MARK: - Filter Tests

@Suite("GitHubViewModel Filters")
struct GitHubViewModelFilterTests {

  @Test("PR filter passes correct state to service")
  @MainActor
  func prFilterPassesCorrectState() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    vm.prFilter = .closed
    await vm.loadPullRequests()

    #expect(mock.listPullRequestsState == "closed")

    mock.resetCalls()
    vm.prFilter = .all
    await vm.loadPullRequests()

    #expect(mock.listPullRequestsState == "all")
  }

  @Test("Issue filter passes correct state to service")
  @MainActor
  func issueFilterPassesCorrectState() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")

    vm.issueFilter = .closed
    await vm.loadIssues()

    #expect(mock.listIssuesState == "closed")
  }
}

// MARK: - Error Handling Tests

@Suite("GitHubViewModel Error Handling")
struct GitHubViewModelErrorTests {

  @Test("submitPRComment sets errorMessage on failure")
  @MainActor
  func submitPRCommentError() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")
    vm.selectedPR = makePR(number: 1)
    vm.newCommentText = "Comment"

    mock.errorToThrow = GitHubCLIError.notAuthenticated
    await vm.submitPRComment()

    #expect(vm.errorMessage != nil)
    #expect(vm.errorMessage?.contains("Not authenticated") == true)
    // Comment text should NOT be cleared on error
    #expect(vm.newCommentText == "Comment")
  }

  @Test("checkoutPR sets errorMessage on failure")
  @MainActor
  func checkoutPRError() async {
    let mock = MockGitHubCLIService()
    mock.repoInfoResult = makeRepoInfo()
    let vm = GitHubViewModel(service: mock)
    await vm.setup(repoPath: "/tmp/repo")
    vm.selectedPR = makePR(number: 1)

    mock.errorToThrow = GitHubCLIError.commandFailed("checkout failed")
    await vm.checkoutPR()

    #expect(vm.errorMessage?.contains("checkout failed") == true)
  }

  @Test("no repo path early returns without calling service")
  @MainActor
  func noRepoPathEarlyReturn() async {
    let mock = MockGitHubCLIService()
    let vm = GitHubViewModel(service: mock)
    // Don't call setup — no currentRepoPath

    await vm.loadPullRequests()
    await vm.loadIssues()
    await vm.loadChecks()

    #expect(mock.listPullRequestsCalled == false)
    #expect(mock.listIssuesCalled == false)
    #expect(mock.getChecksCalled == false)
  }
}
