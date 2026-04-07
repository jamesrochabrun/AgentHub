//
//  GitHubModels.swift
//  AgentHub
//
//  Data models for GitHub CLI integration
//

import Foundation

// MARK: - Shared GitHub Enums

public enum GitHubPullRequestState: Equatable, Sendable {
  case open
  case closed
  case merged
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.uppercased() {
    case "OPEN": self = .open
    case "CLOSED": self = .closed
    case "MERGED": self = .merged
    default: self = .unknown(rawValue)
    }
  }

  public var displayName: String {
    switch self {
    case .open: "Open"
    case .closed: "Closed"
    case .merged: "Merged"
    case .unknown(let value): value
    }
  }
}

public enum GitHubIssueState: Equatable, Sendable {
  case open
  case closed
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.uppercased() {
    case "OPEN": self = .open
    case "CLOSED": self = .closed
    default: self = .unknown(rawValue)
    }
  }

  public var displayName: String {
    switch self {
    case .open: "Open"
    case .closed: "Closed"
    case .unknown(let value): value
    }
  }
}

public enum GitHubMergeability: Equatable, Sendable {
  case mergeable
  case conflicting
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.uppercased() {
    case "MERGEABLE": self = .mergeable
    case "CONFLICTING": self = .conflicting
    default: self = .unknown(rawValue)
    }
  }

  public var displayName: String {
    switch self {
    case .mergeable: "Mergeable"
    case .conflicting: "Conflicting"
    case .unknown(let value): value.capitalized
    }
  }
}

public enum GitHubReviewDecisionState: Equatable, Sendable {
  case approved
  case changesRequested
  case reviewRequired
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.uppercased() {
    case "APPROVED": self = .approved
    case "CHANGES_REQUESTED": self = .changesRequested
    case "REVIEW_REQUIRED": self = .reviewRequired
    default: self = .unknown(rawValue)
    }
  }

  public var displayName: String {
    switch self {
    case .approved: "Approved"
    case .changesRequested: "Changes Requested"
    case .reviewRequired: "Review Required"
    case .unknown(let value): value
    }
  }
}

public enum GitHubCheckStatus: Equatable, Sendable {
  case completed
  case inProgress
  case queued
  case pending
  case pass
  case fail
  case skipping
  case cancel
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.uppercased() {
    case "COMPLETED": self = .completed
    case "IN_PROGRESS": self = .inProgress
    case "QUEUED": self = .queued
    case "PENDING": self = .pending
    case "PASS": self = .pass
    case "FAIL": self = .fail
    case "SKIPPING": self = .skipping
    case "CANCEL", "CANCELLED": self = .cancel
    // StatusContext.state values (legacy commit statuses)
    case "SUCCESS": self = .pass
    case "FAILURE", "ERROR": self = .fail
    default: self = .unknown(rawValue)
    }
  }

  public var displayName: String {
    switch self {
    case .completed: "Completed"
    case .inProgress: "In Progress"
    case .queued: "Queued"
    case .pending: "Pending"
    case .pass: "Pass"
    case .fail: "Fail"
    case .skipping: "Skipping"
    case .cancel: "Cancelled"
    case .unknown(let value): value
    }
  }
}

public enum GitHubCheckConclusion: Equatable, Sendable {
  case success
  case failure
  case error
  case timedOut
  case neutral
  case skipped
  case actionRequired
  case cancelled
  case startupFailure
  case stale
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.uppercased() {
    case "SUCCESS": self = .success
    case "FAILURE": self = .failure
    case "ERROR": self = .error
    case "TIMED_OUT": self = .timedOut
    case "NEUTRAL": self = .neutral
    case "SKIPPED": self = .skipped
    case "ACTION_REQUIRED": self = .actionRequired
    case "CANCELLED": self = .cancelled
    case "STARTUP_FAILURE": self = .startupFailure
    case "STALE": self = .stale
    default: self = .unknown(rawValue)
    }
  }

  public var displayName: String {
    switch self {
    case .success: "Success"
    case .failure: "Failure"
    case .error: "Error"
    case .timedOut: "Timed Out"
    case .neutral: "Neutral"
    case .skipped: "Skipped"
    case .actionRequired: "Action Required"
    case .cancelled: "Cancelled"
    case .startupFailure: "Startup Failure"
    case .stale: "Stale"
    case .unknown(let value): value
    }
  }
}

public enum GitHubCheckBucket: Equatable, Sendable {
  case pass
  case fail
  case pending
  case skipping
  case cancel
  case unknown(String)

  public init(rawValue: String) {
    switch rawValue.lowercased() {
    case "pass": self = .pass
    case "fail": self = .fail
    case "pending": self = .pending
    case "skipping": self = .skipping
    case "cancel": self = .cancel
    default: self = .unknown(rawValue)
    }
  }

  public var displayName: String {
    switch self {
    case .pass: "Pass"
    case .fail: "Fail"
    case .pending: "Pending"
    case .skipping: "Skipping"
    case .cancel: "Cancelled"
    case .unknown(let value): value
    }
  }
}

// MARK: - GitHub Pull Request

/// Represents a GitHub pull request
public struct GitHubPullRequest: Identifiable, Equatable, Sendable, Decodable {
  public let number: Int
  public let title: String
  public let body: String?
  public let state: String
  public let url: String
  public let headRefName: String
  public let baseRefName: String
  public let author: GitHubAuthor?
  public let createdAt: Date?
  public let updatedAt: Date?
  public let isDraft: Bool
  public let mergeable: String?
  public let additions: Int
  public let deletions: Int
  public let changedFiles: Int
  public let reviewDecision: String?
  public let statusCheckRollup: [GitHubCheckRun]?
  public let labels: [GitHubLabel]?
  public let reviewRequests: [GitHubReviewRequest]?
  public let comments: [GitHubComment]?

  public init(
    number: Int,
    title: String,
    body: String?,
    state: String,
    url: String,
    headRefName: String,
    baseRefName: String,
    author: GitHubAuthor?,
    createdAt: Date?,
    updatedAt: Date?,
    isDraft: Bool,
    mergeable: String?,
    additions: Int,
    deletions: Int,
    changedFiles: Int,
    reviewDecision: String?,
    statusCheckRollup: [GitHubCheckRun]?,
    labels: [GitHubLabel]?,
    reviewRequests: [GitHubReviewRequest]?,
    comments: [GitHubComment]?
  ) {
    self.number = number
    self.title = title
    self.body = body
    self.state = state
    self.url = url
    self.headRefName = headRefName
    self.baseRefName = baseRefName
    self.author = author
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.isDraft = isDraft
    self.mergeable = mergeable
    self.additions = additions
    self.deletions = deletions
    self.changedFiles = changedFiles
    self.reviewDecision = reviewDecision
    self.statusCheckRollup = statusCheckRollup
    self.labels = labels
    self.reviewRequests = reviewRequests
    self.comments = comments
  }

  public var id: Int { number }

  public var stateKind: GitHubPullRequestState {
    GitHubPullRequestState(rawValue: state)
  }

  public var reviewDecisionKind: GitHubReviewDecisionState? {
    reviewDecision.map(GitHubReviewDecisionState.init(rawValue:))
  }

  public var mergeabilityKind: GitHubMergeability? {
    mergeable.map(GitHubMergeability.init(rawValue:))
  }

  public var stateDisplayName: String {
    stateKind.displayName
  }

  public var stateIcon: String {
    switch stateKind {
    case .open: return isDraft ? "circle.dotted" : "arrow.triangle.pull"
    case .closed: return "xmark.circle"
    case .merged: return "arrow.triangle.merge"
    case .unknown: return "questionmark.circle"
    }
  }

  public var stateColor: String {
    switch stateKind {
    case .open: return isDraft ? "gray" : "green"
    case .closed: return "red"
    case .merged: return "purple"
    case .unknown: return "gray"
    }
  }

  /// Overall CI status derived from check runs
  public var ciStatus: CIStatus {
    guard let checks = statusCheckRollup, !checks.isEmpty else {
      return .none
    }
    if checks.contains(where: { $0.ciStatus == .pending }) {
      return .pending
    }
    if checks.contains(where: { $0.ciStatus == .failure }) {
      return .failure
    }
    if checks.allSatisfy({ $0.ciStatus == .success || $0.ciStatus == .none }) {
      return .success
    }
    return .none
  }

  enum CodingKeys: String, CodingKey {
    case number, title, body, state, url
    case headRefName, baseRefName
    case author, createdAt, updatedAt
    case isDraft, mergeable
    case additions, deletions, changedFiles
    case reviewDecision
    case statusCheckRollup
    case labels
    case reviewRequests
    case comments
  }
}

// MARK: - CI Status

public enum CIStatus: String, Sendable {
  case success
  case failure
  case pending
  case none

  public var icon: String {
    switch self {
    case .success: return "checkmark.circle.fill"
    case .failure: return "xmark.circle.fill"
    case .pending: return "clock.fill"
    case .none: return "minus.circle"
    }
  }
}

// MARK: - GitHub Issue

/// Represents a GitHub issue
public struct GitHubIssue: Identifiable, Equatable, Sendable, Decodable {
  public let number: Int
  public let title: String
  public let body: String?
  public let state: String
  public let url: String
  public let author: GitHubAuthor?
  public let createdAt: Date?
  public let updatedAt: Date?
  public let labels: [GitHubLabel]?
  public let assignees: [GitHubAuthor]?
  public let comments: [GitHubComment]?

  public var id: Int { number }

  public var stateKind: GitHubIssueState {
    GitHubIssueState(rawValue: state)
  }

  public var stateIcon: String {
    switch stateKind {
    case .open: return "circle.fill"
    case .closed: return "checkmark.circle.fill"
    case .unknown: return "questionmark.circle"
    }
  }
}

// MARK: - Supporting Types

public struct GitHubAuthor: Equatable, Sendable, Decodable {
  public let login: String
  public let name: String?
}

public struct GitHubLabel: Identifiable, Equatable, Sendable, Decodable {
  public let name: String
  public let color: String?
  public let description: String?

  public var id: String { name }
}

public struct GitHubCheckRun: Identifiable, Equatable, Sendable, Decodable {
  public let name: String
  public let status: String
  public let conclusion: String?
  public let bucket: String?
  public let detailsUrl: String?

  public var id: String { name }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // CheckRun uses `name`; StatusContext uses `context`
    name = try c.decodeIfPresent(String.self, forKey: .name)
      ?? c.decodeIfPresent(String.self, forKey: .context)
      ?? ""
    // CheckRun uses `status`; StatusContext uses `state`
    status = try c.decodeIfPresent(String.self, forKey: .status)
      ?? c.decodeIfPresent(String.self, forKey: .state)
      ?? ""
    conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
    bucket = try c.decodeIfPresent(String.self, forKey: .bucket)
    // CheckRun uses `detailsUrl`; StatusContext uses `targetUrl`
    detailsUrl = try c.decodeIfPresent(String.self, forKey: .detailsUrl)
      ?? c.decodeIfPresent(String.self, forKey: .targetUrl)
  }

  private enum CodingKeys: String, CodingKey {
    case name, status, conclusion, bucket, detailsUrl
    case context, state, targetUrl
  }

  public var statusKind: GitHubCheckStatus {
    GitHubCheckStatus(rawValue: status)
  }

  public var conclusionKind: GitHubCheckConclusion? {
    conclusion.map(GitHubCheckConclusion.init(rawValue:))
  }

  public var bucketKind: GitHubCheckBucket? {
    bucket.map(GitHubCheckBucket.init(rawValue:))
  }

  public var ciStatus: CIStatus {
    if let bucketKind {
      switch bucketKind {
      case .pass: return .success
      case .fail, .cancel: return .failure
      case .pending: return .pending
      case .skipping, .unknown: return .none
      }
    }

    if let conclusionKind {
      switch conclusionKind {
      case .success, .neutral, .skipped: return .success
      case .failure, .error, .timedOut, .actionRequired, .cancelled, .startupFailure, .stale:
        return .failure
      case .unknown:
        break
      }
    }

    switch statusKind {
    case .inProgress, .queued, .pending: return .pending
    case .pass: return .success
    case .fail, .cancel: return .failure
    case .skipping, .completed, .unknown: return .none
    }
  }

  public var statusDisplayName: String {
    if let conclusionKind {
      return conclusionKind.displayName
    }
    if let bucketKind {
      return bucketKind.displayName
    }
    return statusKind.displayName
  }

  public var statusIcon: String {
    if let conclusionKind {
      switch conclusionKind {
      case .success: return "checkmark.circle.fill"
      case .failure, .error, .timedOut, .actionRequired, .cancelled, .startupFailure, .stale:
        return "xmark.circle.fill"
      case .neutral, .skipped: return "minus.circle.fill"
      case .unknown:
        break
      }
    }

    if let bucketKind {
      switch bucketKind {
      case .pass: return "checkmark.circle.fill"
      case .fail, .cancel: return "xmark.circle.fill"
      case .pending: return "clock.fill"
      case .skipping: return "minus.circle.fill"
      case .unknown:
        break
      }
    }

    switch statusKind {
    case .inProgress, .queued, .pending: return "clock.fill"
    case .pass: return "checkmark.circle.fill"
    case .fail, .cancel: return "xmark.circle.fill"
    case .skipping: return "minus.circle.fill"
    case .completed, .unknown: return "questionmark.circle"
    }
  }

  public init(
    name: String,
    status: String,
    conclusion: String? = nil,
    bucket: String? = nil,
    detailsUrl: String? = nil
  ) {
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.bucket = bucket
    self.detailsUrl = detailsUrl
  }
}

public struct GitHubReviewRequest: Equatable, Sendable, Decodable {
  public let login: String?
  public let name: String?
  public let slug: String?
}

public struct GitHubComment: Identifiable, Equatable, Sendable, Decodable {
  /// Stable identifier (falls back to UUID if API doesn't provide one)
  public let id: String
  public let author: GitHubAuthor?
  public let body: String
  public let createdAt: Date?
  public let path: String?
  public let line: Int?
  public let diffHunk: String?

  /// Whether this is an inline code review comment (has a file path)
  public var isReviewComment: Bool {
    path != nil
  }

  enum CodingKeys: String, CodingKey {
    case id, author, body, createdAt, path, line, diffHunk
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // id can be Int or String from different GitHub APIs
    if let intId = try? container.decode(Int.self, forKey: .id) {
      self.id = String(intId)
    } else if let strId = try? container.decode(String.self, forKey: .id) {
      self.id = strId
    } else {
      self.id = UUID().uuidString
    }
    self.author = try container.decodeIfPresent(GitHubAuthor.self, forKey: .author)
    self.body = try container.decode(String.self, forKey: .body)
    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    self.path = try container.decodeIfPresent(String.self, forKey: .path)
    self.line = try container.decodeIfPresent(Int.self, forKey: .line)
    self.diffHunk = try container.decodeIfPresent(String.self, forKey: .diffHunk)
  }

  public init(
    id: String? = nil,
    author: GitHubAuthor?,
    body: String,
    createdAt: Date?,
    path: String?,
    line: Int?,
    diffHunk: String?
  ) {
    self.id = id ?? UUID().uuidString
    self.author = author
    self.body = body
    self.createdAt = createdAt
    self.path = path
    self.line = line
    self.diffHunk = diffHunk
  }
}

// MARK: - GitHub PR Diff File

/// A file changed in a pull request
public struct GitHubPRFile: Identifiable, Equatable, Sendable {
  public let filename: String
  public let status: String
  public let additions: Int
  public let deletions: Int
  public let patch: String?

  public var id: String { filename }

  public var statusIcon: String {
    switch status {
    case "added": return "plus.circle"
    case "removed": return "minus.circle"
    case "modified": return "pencil.circle"
    case "renamed": return "arrow.right.circle"
    default: return "doc.circle"
    }
  }
}

// MARK: - GitHub Repository Info

/// Basic repository information from gh
public struct GitHubRepoInfo: Equatable, Sendable {
  public let owner: String
  public let name: String
  public let fullName: String
  public let defaultBranch: String
  public let isPrivate: Bool
  public let url: String
}

// MARK: - PR Creation Input

/// Input for creating a new pull request
public struct GitHubPRCreationInput: Sendable {
  public let title: String
  public let body: String
  public let baseBranch: String
  public let headBranch: String
  public let isDraft: Bool
  public let labels: [String]
  public let reviewers: [String]

  public init(
    title: String,
    body: String,
    baseBranch: String,
    headBranch: String,
    isDraft: Bool = false,
    labels: [String] = [],
    reviewers: [String] = []
  ) {
    self.title = title
    self.body = body
    self.baseBranch = baseBranch
    self.headBranch = headBranch
    self.isDraft = isDraft
    self.labels = labels
    self.reviewers = reviewers
  }
}

// MARK: - PR Review Input

/// Input for submitting a PR review
public struct GitHubReviewInput: Sendable {
  public enum Event: String, Sendable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
  }

  public let event: Event
  public let body: String

  public init(event: Event, body: String = "") {
    self.event = event
    self.body = body
  }
}
