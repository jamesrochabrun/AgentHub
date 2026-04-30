//
//  GitHubViewModel.swift
//  AgentHub
//
//  ViewModel for GitHub integration state management
//

import Foundation

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
  case draft = "Draft"
  case merged = "Merged"
  case closed = "Closed"
  case all = "All"

  public var id: String { rawValue }

  /// gh CLI state used when querying the API.
  /// Draft is a client-side refinement over open; merged is a client-side refinement over closed.
  var ghState: String {
    switch self {
    case .open, .draft: return "open"
    case .merged, .closed: return "closed"
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

// MARK: - Setup State

public enum GitHubSetupState: Equatable, Sendable {
  case checking
  case ghNotInstalled
  case notAuthenticated
  case ready
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

  /// Current setup state for gh availability, authentication, and repository metadata.
  public var setupState: GitHubSetupState = .checking

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

  /// PR filter: show only my PRs
  public var showOnlyMyPRs: Bool = false

  /// PR filter: selected labels
  public var selectedLabels: Set<String> = []

  /// Available repository labels
  public var availableLabels: [GitHubLabel] = []
  public var labelsLoadingState: GitHubLoadingState = .idle

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
    setupState = .checking
    repoInfo = nil

    isGHInstalled = await service.isInstalled()
    guard isGHInstalled else {
      isAuthenticated = false
      setupState = .ghNotInstalled
      return
    }

    isAuthenticated = await service.isAuthenticated(at: repoPath)
    guard isAuthenticated else {
      setupState = .notAuthenticated
      return
    }

    do {
      repoInfo = try await service.getRepoInfo(at: repoPath)
    } catch {
      GitHubLogger.github.error("Failed to get repo info: \(error.localizedDescription)")
    }

    setupState = .ready
  }

  // MARK: - Pull Requests

  /// Loads the list of pull requests
  public func loadPullRequests() async {
    guard let repoPath = currentRepoPath else { return }
    prLoadingState = .loading

    do {
      let raw = try await service.listPullRequests(
        at: repoPath,
        state: prFilter.ghState,
        limit: 30,
        authoredByMe: showOnlyMyPRs,
        labels: Array(selectedLabels)
      )
      pullRequests = applyClientSideFilter(raw, filter: prFilter)
      prLoadingState = .loaded
    } catch {
      prLoadingState = .error(error.localizedDescription)
      GitHubLogger.github.error("Failed to load PRs: \(error.localizedDescription)")
    }
  }

  /// Refines the raw list returned by `gh` for filters that can't be expressed in the query.
  /// - `.draft`: open PRs with `isDraft == true`
  /// - `.open`:  open PRs with `isDraft == false` (so the draft chip isn't double-counted)
  /// - `.merged`: closed PRs that were merged
  /// - `.closed`: closed PRs that were not merged
  /// - `.all`: no refinement
  private func applyClientSideFilter(
    _ prs: [GitHubPullRequest],
    filter: GitHubPRFilter
  ) -> [GitHubPullRequest] {
    switch filter {
    case .draft:  return prs.filter { $0.isDraft }
    case .open:   return prs.filter { !$0.isDraft }
    case .merged: return prs.filter { $0.stateKind == .merged }
    case .closed: return prs.filter { $0.stateKind == .closed }
    case .all:    return prs
    }
  }

  /// Count of loaded PRs that fall into a given filter. Used for the filter chip badges.
  /// Note: counts reflect the currently loaded set, not the full remote state.
  public func filterCount(_ filter: GitHubPRFilter) -> Int {
    applyClientSideFilter(pullRequests, filter: filter).count
  }

  /// Loads repository labels if not already loaded
  public func loadLabelsIfNeeded() async {
    guard let repoPath = currentRepoPath,
          availableLabels.isEmpty,
          labelsLoadingState != .loading else { return }
    labelsLoadingState = .loading
    do {
      availableLabels = try await service.listLabels(at: repoPath)
      labelsLoadingState = .loaded
    } catch {
      labelsLoadingState = .error(error.localizedDescription)
      GitHubLogger.github.error("Failed to load labels: \(error.localizedDescription)")
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
        GitHubLogger.github.warning("Failed to load PR files: \(error.localizedDescription)")
      }
    } catch {
      guard !Task.isCancelled, selectedPR == nil || selectedPR?.number == number else { return }
      prDetailLoadingState = .error(error.localizedDescription)
      GitHubLogger.github.error("Failed to load PR detail: \(error.localizedDescription)")
    }
  }

  /// Loads the PR for the current branch
  public func loadCurrentBranchPR() async {
    guard let repoPath = currentRepoPath else { return }
    do {
      currentBranchPR = try await service.getCurrentBranchPR(at: repoPath)
    } catch {
      GitHubLogger.github.info("No PR for current branch: \(error.localizedDescription)")
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
      GitHubLogger.github.error("Failed to load issues: \(error.localizedDescription)")
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
      GitHubLogger.github.error("Failed to load issue: \(error.localizedDescription)")
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
