//
//  MockGitHubCLIService.swift
//  AgentHubTests
//
//  Mock implementation of GitHubCLIServiceProtocol for unit testing
//

import Foundation
@testable import AgentHubCore

/// Mock GitHub CLI service for testing ViewModels and other consumers.
///
/// Configure return values and errors before each test, then assert on
/// recorded calls to verify behavior.
///
/// ```swift
/// let mock = MockGitHubCLIService()
/// mock.pullRequestsResult = [somePR]
/// let vm = GitHubViewModel(service: mock)
/// await vm.loadPullRequests()
/// #expect(mock.listPullRequestsCalled)
/// ```
final class MockGitHubCLIService: GitHubCLIServiceProtocol, @unchecked Sendable {

  // MARK: - Configuration

  /// If set, methods that `throws` will throw this error instead of returning
  var errorToThrow: Error?

  // MARK: - CLI Detection

  var isInstalledResult = true
  var isAuthenticatedResult = true
  var isInstalledCallCount = 0
  var isAuthenticatedCallCount = 0
  var lastAuthenticatedRepoPath: String?

  func isInstalled() async -> Bool {
    isInstalledCallCount += 1
    return isInstalledResult
  }

  func isAuthenticated(at repoPath: String) async -> Bool {
    isAuthenticatedCallCount += 1
    lastAuthenticatedRepoPath = repoPath
    return isAuthenticatedResult
  }

  // MARK: - Repository Info

  var repoInfoResult: GitHubRepoInfo?
  var getRepoInfoCalled = false

  func getRepoInfo(at repoPath: String) async throws -> GitHubRepoInfo {
    getRepoInfoCalled = true
    if let error = errorToThrow { throw error }
    guard let result = repoInfoResult else {
      throw GitHubCLIError.commandFailed("No mock repoInfoResult configured")
    }
    return result
  }

  // MARK: - Pull Requests

  var pullRequestsResult: [GitHubPullRequest] = []
  var listPullRequestsCalled = false
  var listPullRequestsState: String?
  var listPullRequestsLimit: Int?

  func listPullRequests(at repoPath: String, state: String, limit: Int, authoredByMe: Bool, labels: [String]) async throws -> [GitHubPullRequest] {
    listPullRequestsCalled = true
    listPullRequestsState = state
    listPullRequestsLimit = limit
    if let error = errorToThrow { throw error }
    return pullRequestsResult
  }

  var labelsResult: [GitHubLabel] = []

  func listLabels(at repoPath: String) async throws -> [GitHubLabel] {
    if let error = errorToThrow { throw error }
    return labelsResult
  }

  var pullRequestResult: GitHubPullRequest?
  var getPullRequestCalled = false
  var getPullRequestNumber: Int?

  func getPullRequest(number: Int, at repoPath: String) async throws -> GitHubPullRequest {
    getPullRequestCalled = true
    getPullRequestNumber = number
    if let error = errorToThrow { throw error }
    guard let result = pullRequestResult else {
      throw GitHubCLIError.commandFailed("No mock pullRequestResult configured")
    }
    return result
  }

  var currentBranchPRResult: GitHubPullRequest?
  var currentBranchPRResults: [Result<GitHubPullRequest?, Error>] = []
  var currentBranchPRDelay: TimeInterval = 0
  var getCurrentBranchPRCalled = false
  var getCurrentBranchPRCallCount = 0
  var getCurrentBranchPRRepoPath: String?

  func getCurrentBranchPR(at repoPath: String) async throws -> GitHubPullRequest? {
    getCurrentBranchPRCalled = true
    getCurrentBranchPRCallCount += 1
    getCurrentBranchPRRepoPath = repoPath
    if currentBranchPRDelay > 0 {
      try? await Task.sleep(for: .milliseconds(Int(currentBranchPRDelay * 1_000)))
    }
    if !currentBranchPRResults.isEmpty {
      let nextResult = currentBranchPRResults.removeFirst()
      switch nextResult {
      case .success(let result):
        return result
      case .failure(let error):
        throw error
      }
    }
    if let error = errorToThrow { throw error }
    return currentBranchPRResult
  }

  var pullRequestDiffResult = ""
  var getPullRequestDiffCalled = false

  func getPullRequestDiff(number: Int, at repoPath: String) async throws -> String {
    getPullRequestDiffCalled = true
    if let error = errorToThrow { throw error }
    return pullRequestDiffResult
  }

  var pullRequestFilesResult: [GitHubPRFile] = []
  var getPullRequestFilesCalled = false

  func getPullRequestFiles(number: Int, at repoPath: String) async throws -> [GitHubPRFile] {
    getPullRequestFilesCalled = true
    if let error = errorToThrow { throw error }
    return pullRequestFilesResult
  }

  var reviewCommentsResult: [GitHubComment] = []
  var getPullRequestReviewCommentsCalled = false

  func getPullRequestReviewComments(number: Int, at repoPath: String) async throws -> [GitHubComment] {
    getPullRequestReviewCommentsCalled = true
    if let error = errorToThrow { throw error }
    return reviewCommentsResult
  }

  var createPullRequestResult: GitHubPullRequest?
  var createPullRequestCalled = false
  var createPullRequestInput: GitHubPRCreationInput?

  func createPullRequest(input: GitHubPRCreationInput, at repoPath: String) async throws -> GitHubPullRequest {
    createPullRequestCalled = true
    createPullRequestInput = input
    if let error = errorToThrow { throw error }
    guard let result = createPullRequestResult else {
      throw GitHubCLIError.commandFailed("No mock createPullRequestResult configured")
    }
    return result
  }

  var submitReviewCalled = false
  var submitReviewPRNumber: Int?
  var submitReviewInput: GitHubReviewInput?

  func submitReview(prNumber: Int, review: GitHubReviewInput, at repoPath: String) async throws {
    submitReviewCalled = true
    submitReviewPRNumber = prNumber
    submitReviewInput = review
    if let error = errorToThrow { throw error }
  }

  var addPRCommentCalled = false
  var addPRCommentPRNumber: Int?
  var addPRCommentBody: String?

  func addPRComment(prNumber: Int, body: String, at repoPath: String) async throws {
    addPRCommentCalled = true
    addPRCommentPRNumber = prNumber
    addPRCommentBody = body
    if let error = errorToThrow { throw error }
  }

  var mergePullRequestCalled = false
  var mergePullRequestNumber: Int?
  var mergePullRequestMethod: String?

  func mergePullRequest(number: Int, method: String, at repoPath: String) async throws {
    mergePullRequestCalled = true
    mergePullRequestNumber = number
    mergePullRequestMethod = method
    if let error = errorToThrow { throw error }
  }

  var checkoutPRCalled = false
  var checkoutPRNumber: Int?

  func checkoutPR(number: Int, at repoPath: String) async throws {
    checkoutPRCalled = true
    checkoutPRNumber = number
    if let error = errorToThrow { throw error }
  }

  // MARK: - Issues

  var issuesResult: [GitHubIssue] = []
  var listIssuesCalled = false
  var listIssuesState: String?

  func listIssues(at repoPath: String, state: String, limit: Int) async throws -> [GitHubIssue] {
    listIssuesCalled = true
    listIssuesState = state
    if let error = errorToThrow { throw error }
    return issuesResult
  }

  var issueResult: GitHubIssue?
  var getIssueCalled = false
  var getIssueNumber: Int?

  func getIssue(number: Int, at repoPath: String) async throws -> GitHubIssue {
    getIssueCalled = true
    getIssueNumber = number
    if let error = errorToThrow { throw error }
    guard let result = issueResult else {
      throw GitHubCLIError.commandFailed("No mock issueResult configured")
    }
    return result
  }

  var addIssueCommentCalled = false
  var addIssueCommentNumber: Int?
  var addIssueCommentBody: String?

  func addIssueComment(issueNumber: Int, body: String, at repoPath: String) async throws {
    addIssueCommentCalled = true
    addIssueCommentNumber = issueNumber
    addIssueCommentBody = body
    if let error = errorToThrow { throw error }
  }

  // MARK: - CI/CD

  var checksResult: [GitHubCheckRun] = []
  var getChecksCalled = false
  var getChecksPRNumber: Int?

  func getChecks(prNumber: Int?, at repoPath: String) async throws -> [GitHubCheckRun] {
    getChecksCalled = true
    getChecksPRNumber = prNumber
    if let error = errorToThrow { throw error }
    return checksResult
  }

  var workflowRunsResult = ""
  var listWorkflowRunsCalled = false

  func listWorkflowRuns(at repoPath: String, limit: Int) async throws -> String {
    listWorkflowRunsCalled = true
    if let error = errorToThrow { throw error }
    return workflowRunsResult
  }

  // MARK: - Reset

  /// Resets all recorded call state (but keeps configured results)
  func resetCalls() {
    isInstalledCallCount = 0
    isAuthenticatedCallCount = 0
    lastAuthenticatedRepoPath = nil
    getRepoInfoCalled = false
    listPullRequestsCalled = false
    listPullRequestsState = nil
    listPullRequestsLimit = nil
    getPullRequestCalled = false
    getPullRequestNumber = nil
    getCurrentBranchPRCalled = false
    getCurrentBranchPRCallCount = 0
    getCurrentBranchPRRepoPath = nil
    getPullRequestDiffCalled = false
    getPullRequestFilesCalled = false
    getPullRequestReviewCommentsCalled = false
    createPullRequestCalled = false
    createPullRequestInput = nil
    submitReviewCalled = false
    submitReviewPRNumber = nil
    submitReviewInput = nil
    addPRCommentCalled = false
    addPRCommentPRNumber = nil
    addPRCommentBody = nil
    mergePullRequestCalled = false
    mergePullRequestNumber = nil
    mergePullRequestMethod = nil
    checkoutPRCalled = false
    checkoutPRNumber = nil
    listIssuesCalled = false
    listIssuesState = nil
    getIssueCalled = false
    getIssueNumber = nil
    addIssueCommentCalled = false
    addIssueCommentNumber = nil
    addIssueCommentBody = nil
    getChecksCalled = false
    getChecksPRNumber = nil
    listWorkflowRunsCalled = false
  }
}
