//
//  GitHubViewModel.swift
//  AgentHub
//
//  ViewModel for GitHub integration state management
//

import Foundation
import os

// MARK: - GitHub Tab

/// Tabs in the GitHub panel
public enum GitHubTab: String, CaseIterable, Identifiable, Sendable {
  case pullRequests = "Pull Requests"
  case issues = "Issues"

  public var id: String { rawValue }

  public var icon: String {
    switch self {
    case .pullRequests: return "arrow.triangle.pull"
    case .issues: return "exclamationmark.circle"
    }
  }
}

// MARK: - PR Filter

/// Filter for PR list state
public enum GitHubPRFilter: String, CaseIterable, Identifiable, Sendable {
  case open = "Open"
  case closed = "Closed"
  case all = "All"

  public var id: String { rawValue }

  var ghState: String {
    switch self {
    case .open: return "open"
    case .closed: return "closed"
    case .all: return "all"
    }
  }
}

// MARK: - Issue Filter

public enum GitHubIssueFilter: String, CaseIterable, Identifiable, Sendable {
  case open = "Open"
  case closed = "Closed"
  case all = "All"

  public var id: String { rawValue }

  var ghState: String {
    switch self {
    case .open: return "open"
    case .closed: return "closed"
    case .all: return "all"
    }
  }
}

// MARK: - Loading State

public enum GitHubLoadingState: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case error(String)
}

// MARK: - Checkout State

public enum CheckoutState: Equatable, Sendable {
  case idle
  case loading
  case success
  case error(String)
}

// MARK: - GitHubViewModel

@MainActor
@Observable
public final class GitHubViewModel {

  // MARK: - State

  /// Whether gh CLI is available
  public var isGHInstalled: Bool = false

  /// Whether user is authenticated
  public var isAuthenticated: Bool = false

  /// Repository info
  public var repoInfo: GitHubRepoInfo?

  /// Current selected tab
  public var selectedTab: GitHubTab = .pullRequests

  /// PR list state
  public var pullRequests: [GitHubPullRequest] = []
  public var prFilter: GitHubPRFilter = .open
  public var prLoadingState: GitHubLoadingState = .idle

  /// Selected PR for detail view
  public var selectedPR: GitHubPullRequest?
  public var selectedPRFiles: [GitHubPRFile] = []
  public var selectedPRDiff: String = ""
  public var selectedPRReviewComments: [GitHubComment] = []
  public var prDetailLoadingState: GitHubLoadingState = .idle

  /// PR for the current branch
  public var currentBranchPR: GitHubPullRequest?

  /// Issue list state
  public var issues: [GitHubIssue] = []
  public var issueFilter: GitHubIssueFilter = .open
  public var issueLoadingState: GitHubLoadingState = .idle

  /// Selected issue for detail view
  public var selectedIssue: GitHubIssue?
  public var issueDetailLoadingState: GitHubLoadingState = .idle

  /// CI checks
  public var checks: [GitHubCheckRun] = []
  public var checksLoadingState: GitHubLoadingState = .idle
  public private(set) var loadedChecksPRNumber: Int?

  /// Comment input
  public var newCommentText: String = ""
  public var isSubmittingComment: Bool = false

  /// Review input
  public var reviewBody: String = ""
  public var isSubmittingReview: Bool = false

  /// Checkout state
  public var checkoutState: CheckoutState = .idle

  /// Error alert
  public var errorMessage: String?

  // MARK: - Dependencies

  private let service: any GitHubCLIServiceProtocol
  private var currentRepoPath: String?
  private var prDetailTask: Task<Void, Never>?
  private var issueDetailTask: Task<Void, Never>?

  // MARK: - Init

  public init(service: any GitHubCLIServiceProtocol = GitHubCLIService()) {
    self.service = service
  }

  // MARK: - Setup

  /// Initializes the GitHub integration for a repository path
  public func setup(repoPath: String) async {
    currentRepoPath = repoPath

    isGHInstalled = await service.isInstalled()
    guard isGHInstalled else { return }

    isAuthenticated = await service.isAuthenticated(at: repoPath)
    guard isAuthenticated else { return }

    do {
      repoInfo = try await service.getRepoInfo(at: repoPath)
    } catch {
      AppLogger.github.error("Failed to get repo info: \(error.localizedDescription)")
    }
  }

  // MARK: - Pull Requests

  /// Loads the list of pull requests
  public func loadPullRequests() async {
    guard let repoPath = currentRepoPath else { return }
    prLoadingState = .loading

    do {
      pullRequests = try await service.listPullRequests(at: repoPath, state: prFilter.ghState, limit: 30)
      prLoadingState = .loaded
    } catch {
      prLoadingState = .error(error.localizedDescription)
      AppLogger.github.error("Failed to load PRs: \(error.localizedDescription)")
    }
  }

  /// Loads details for a specific PR
  public func loadPRDetail(number: Int) async {
    guard let repoPath = currentRepoPath else { return }
    prDetailLoadingState = .loading

    do {
      async let prTask = service.getPullRequest(number: number, at: repoPath)
      async let diffTask = service.getPullRequestDiff(number: number, at: repoPath)
      async let commentsTask = service.getPullRequestReviewComments(number: number, at: repoPath)

      let (pr, diff, comments) = try await (prTask, diffTask, commentsTask)
      guard !Task.isCancelled, selectedPR == nil || selectedPR?.number == number else { return }

      selectedPR = pr
      selectedPRDiff = diff
      selectedPRReviewComments = comments
      prDetailLoadingState = .loaded

      // Load files separately (can be slower)
      do {
        let files = try await service.getPullRequestFiles(number: number, at: repoPath)
        guard !Task.isCancelled, selectedPR == nil || selectedPR?.number == number else { return }
        selectedPRFiles = files
      } catch {
        AppLogger.github.warning("Failed to load PR files: \(error.localizedDescription)")
      }
    } catch {
      guard !Task.isCancelled, selectedPR == nil || selectedPR?.number == number else { return }
      prDetailLoadingState = .error(error.localizedDescription)
      AppLogger.github.error("Failed to load PR detail: \(error.localizedDescription)")
    }
  }

  /// Loads the PR for the current branch
  public func loadCurrentBranchPR() async {
    guard let repoPath = currentRepoPath else { return }
    do {
      currentBranchPR = try await service.getCurrentBranchPR(at: repoPath)
    } catch {
      AppLogger.github.info("No PR for current branch: \(error.localizedDescription)")
    }
  }

  /// Submits a comment on the selected PR
  public func submitPRComment() async {
    guard let repoPath = currentRepoPath,
          let pr = selectedPR,
          !newCommentText.isEmpty else { return }

    isSubmittingComment = true
    defer { isSubmittingComment = false }

    do {
      try await service.addPRComment(prNumber: pr.number, body: newCommentText, at: repoPath)
      newCommentText = ""
      // Reload PR to get updated comments
      await loadPRDetail(number: pr.number)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Submits a review on the selected PR
  public func submitReview(event: GitHubReviewInput.Event) async {
    guard let repoPath = currentRepoPath,
          let pr = selectedPR else { return }

    isSubmittingReview = true
    defer { isSubmittingReview = false }

    do {
      let review = GitHubReviewInput(event: event, body: reviewBody)
      try await service.submitReview(prNumber: pr.number, review: review, at: repoPath)
      reviewBody = ""
      await loadPRDetail(number: pr.number)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Checks out the selected PR's branch
  public func checkoutPR() async {
    guard let repoPath = currentRepoPath, let pr = selectedPR else { return }
    checkoutState = .loading
    do {
      try await service.checkoutPR(number: pr.number, at: repoPath)
      checkoutState = .success
      Task {
        try? await Task.sleep(for: .seconds(2))
        if checkoutState == .success {
          checkoutState = .idle
        }
      }
    } catch {
      checkoutState = .error(error.localizedDescription)
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - Issues

  /// Loads the list of issues
  public func loadIssues() async {
    guard let repoPath = currentRepoPath else { return }
    issueLoadingState = .loading

    do {
      issues = try await service.listIssues(at: repoPath, state: issueFilter.ghState, limit: 30)
      issueLoadingState = .loaded
    } catch {
      issueLoadingState = .error(error.localizedDescription)
      AppLogger.github.error("Failed to load issues: \(error.localizedDescription)")
    }
  }

  /// Loads details for a specific issue
  public func loadIssueDetail(number: Int) async {
    guard let repoPath = currentRepoPath else { return }
    issueDetailLoadingState = .loading

    do {
      let issue = try await service.getIssue(number: number, at: repoPath)
      guard !Task.isCancelled, selectedIssue == nil || selectedIssue?.number == number else { return }
      selectedIssue = issue
      issueDetailLoadingState = .loaded
    } catch {
      guard !Task.isCancelled, selectedIssue == nil || selectedIssue?.number == number else { return }
      issueDetailLoadingState = .error(error.localizedDescription)
      AppLogger.github.error("Failed to load issue: \(error.localizedDescription)")
    }
  }

  /// Submits a comment on the selected issue
  public func submitIssueComment() async {
    guard let repoPath = currentRepoPath,
          let issue = selectedIssue,
          !newCommentText.isEmpty else { return }

    isSubmittingComment = true
    defer { isSubmittingComment = false }

    do {
      try await service.addIssueComment(issueNumber: issue.number, body: newCommentText, at: repoPath)
      newCommentText = ""
      await loadIssueDetail(number: issue.number)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  // MARK: - CI Checks

  /// Loads CI checks for a PR
  public func loadChecks(prNumber: Int? = nil) async {
    guard let repoPath = currentRepoPath else { return }
    checksLoadingState = .loading

    do {
      checks = try await service.getChecks(prNumber: prNumber, at: repoPath)
      loadedChecksPRNumber = prNumber
      checksLoadingState = .loaded
    } catch {
      loadedChecksPRNumber = nil
      checksLoadingState = .error(error.localizedDescription)
    }
  }

  // MARK: - Navigation

  /// Selects a PR and loads its details
  public func selectPR(_ pr: GitHubPullRequest) {
    prDetailTask?.cancel()
    selectedPR = pr
    selectedPRFiles = []
    selectedPRDiff = ""
    selectedPRReviewComments = []
    checks = []
    checksLoadingState = .idle
    loadedChecksPRNumber = nil

    prDetailTask = Task { [number = pr.number] in
      await loadPRDetail(number: number)
    }
  }

  /// Deselects the current PR (back to list)
  public func deselectPR() {
    prDetailTask?.cancel()
    selectedPR = nil
    selectedPRFiles = []
    selectedPRDiff = ""
    selectedPRReviewComments = []
    prDetailLoadingState = .idle
    checks = []
    checksLoadingState = .idle
    loadedChecksPRNumber = nil
  }

  /// Selects an issue and loads its details
  public func selectIssue(_ issue: GitHubIssue) {
    issueDetailTask?.cancel()
    selectedIssue = issue
    issueDetailTask = Task { [number = issue.number] in
      await loadIssueDetail(number: number)
    }
  }

  /// Deselects the current issue
  public func deselectIssue() {
    issueDetailTask?.cancel()
    selectedIssue = nil
    issueDetailLoadingState = .idle
  }
}
