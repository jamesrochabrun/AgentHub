//
//  GitHubCLIServiceProtocol.swift
//  AgentHub
//
//  Protocol for GitHub CLI operations, enabling dependency injection and testing
//

import Foundation

/// Protocol defining GitHub CLI operations for PR, issue, and CI management.
///
/// Concrete implementations:
/// - `GitHubCLIService` — real implementation wrapping the `gh` CLI
///
/// Use `any GitHubCLIServiceProtocol` in ViewModels and services to enable
/// mock injection for unit tests.
public protocol GitHubCLIServiceProtocol: AnyObject, Sendable {

  // MARK: - CLI Detection

  /// Checks if the gh CLI is installed
  func isInstalled() async -> Bool

  /// Checks if the user is authenticated with gh for the given repository
  func isAuthenticated(at repoPath: String) async -> Bool

  // MARK: - Repository Info

  /// Gets repository information for the given path
  func getRepoInfo(at repoPath: String) async throws -> GitHubRepoInfo

  // MARK: - Pull Requests

  /// Lists pull requests for the repository
  func listPullRequests(at repoPath: String, state: String, limit: Int) async throws -> [GitHubPullRequest]

  /// Gets details of a specific pull request
  func getPullRequest(number: Int, at repoPath: String) async throws -> GitHubPullRequest

  /// Gets the PR for the current branch (if any)
  func getCurrentBranchPR(at repoPath: String) async throws -> GitHubPullRequest?

  /// Gets the unified diff for a pull request
  func getPullRequestDiff(number: Int, at repoPath: String) async throws -> String

  /// Gets files changed in a pull request
  func getPullRequestFiles(number: Int, at repoPath: String) async throws -> [GitHubPRFile]

  /// Gets review comments on a pull request
  func getPullRequestReviewComments(number: Int, at repoPath: String) async throws -> [GitHubComment]

  /// Creates a new pull request
  func createPullRequest(input: GitHubPRCreationInput, at repoPath: String) async throws -> GitHubPullRequest

  /// Submits a review on a pull request
  func submitReview(prNumber: Int, review: GitHubReviewInput, at repoPath: String) async throws

  /// Adds a comment to a pull request
  func addPRComment(prNumber: Int, body: String, at repoPath: String) async throws

  /// Merges a pull request
  func mergePullRequest(number: Int, method: String, at repoPath: String) async throws

  /// Checks out a PR branch locally
  func checkoutPR(number: Int, at repoPath: String) async throws

  // MARK: - Issues

  /// Lists issues for the repository
  func listIssues(at repoPath: String, state: String, limit: Int) async throws -> [GitHubIssue]

  /// Gets details of a specific issue
  func getIssue(number: Int, at repoPath: String) async throws -> GitHubIssue

  /// Adds a comment to an issue
  func addIssueComment(issueNumber: Int, body: String, at repoPath: String) async throws

  // MARK: - CI/CD

  /// Gets CI check status for a PR or the current branch
  func getChecks(prNumber: Int?, at repoPath: String) async throws -> [GitHubCheckRun]

  /// Lists recent workflow runs
  func listWorkflowRuns(at repoPath: String, limit: Int) async throws -> String
}
