//
//  GitHubModels.swift
//  AgentHub
//
//  Data models for GitHub CLI integration
//

import Foundation

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

  public var id: Int { number }

  public var stateDisplayName: String {
    switch state.uppercased() {
    case "OPEN": return "Open"
    case "CLOSED": return "Closed"
    case "MERGED": return "Merged"
    default: return state
    }
  }

  public var stateIcon: String {
    switch state.uppercased() {
    case "OPEN": return isDraft ? "circle.dotted" : "arrow.triangle.pull"
    case "CLOSED": return "xmark.circle"
    case "MERGED": return "arrow.triangle.merge"
    default: return "questionmark.circle"
    }
  }

  public var stateColor: String {
    switch state.uppercased() {
    case "OPEN": return isDraft ? "gray" : "green"
    case "CLOSED": return "red"
    case "MERGED": return "purple"
    default: return "gray"
    }
  }

  /// Overall CI status derived from check runs
  public var ciStatus: CIStatus {
    guard let checks = statusCheckRollup, !checks.isEmpty else {
      return .none
    }
    if checks.contains(where: { $0.status == "IN_PROGRESS" || $0.status == "QUEUED" }) {
      return .pending
    }
    if checks.allSatisfy({ $0.conclusion == "SUCCESS" || $0.conclusion == "NEUTRAL" || $0.conclusion == "SKIPPED" }) {
      return .success
    }
    if checks.contains(where: { $0.conclusion == "FAILURE" || $0.conclusion == "ERROR" || $0.conclusion == "TIMED_OUT" }) {
      return .failure
    }
    return .pending
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

  public var stateIcon: String {
    switch state.uppercased() {
    case "OPEN": return "circle.fill"
    case "CLOSED": return "checkmark.circle.fill"
    default: return "questionmark.circle"
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
  public let detailsUrl: String?

  public var id: String { name }

  public var statusIcon: String {
    switch conclusion?.uppercased() {
    case "SUCCESS": return "checkmark.circle.fill"
    case "FAILURE", "ERROR", "TIMED_OUT": return "xmark.circle.fill"
    case "NEUTRAL", "SKIPPED": return "minus.circle.fill"
    default:
      if status == "IN_PROGRESS" || status == "QUEUED" {
        return "clock.fill"
      }
      return "questionmark.circle"
    }
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
