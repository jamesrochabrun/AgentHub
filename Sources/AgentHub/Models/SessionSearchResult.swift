//
//  SessionSearchResult.swift
//  AgentHub
//
//  Created by Assistant on 1/14/26.
//

import Foundation

// MARK: - SessionSearchResult

/// Represents a search result from global session search
public struct SessionSearchResult: Identifiable, Sendable, Equatable {
  public let id: String  // sessionId
  public let slug: String
  public let projectPath: String
  public let gitBranch: String?
  public let firstMessage: String?
  public let summaries: [String]
  public let lastActivityAt: Date
  public let matchedField: SearchMatchField
  public let matchedText: String

  public init(
    id: String,
    slug: String,
    projectPath: String,
    gitBranch: String?,
    firstMessage: String?,
    summaries: [String],
    lastActivityAt: Date,
    matchedField: SearchMatchField,
    matchedText: String
  ) {
    self.id = id
    self.slug = slug
    self.projectPath = projectPath
    self.gitBranch = gitBranch
    self.firstMessage = firstMessage
    self.summaries = summaries
    self.lastActivityAt = lastActivityAt
    self.matchedField = matchedField
    self.matchedText = matchedText
  }

  /// Returns the repository name (last path component)
  public var repositoryName: String {
    URL(fileURLWithPath: projectPath).lastPathComponent
  }
}

// MARK: - SearchMatchField

/// Indicates which field matched the search query
public enum SearchMatchField: String, Sendable, Equatable {
  case slug
  case summary
  case path
  case gitBranch
  case firstMessage

  /// Icon name for the match field
  public var iconName: String {
    switch self {
    case .slug: return "tag"
    case .summary: return "doc.text"
    case .path: return "folder"
    case .gitBranch: return "arrow.triangle.branch"
    case .firstMessage: return "text.bubble"
    }
  }

  /// Display label for the match field
  public var displayLabel: String {
    switch self {
    case .slug: return "Session"
    case .summary: return "Summary"
    case .path: return "Path"
    case .gitBranch: return "Branch"
    case .firstMessage: return "Message"
    }
  }
}

// MARK: - SessionIndexEntry

/// Lightweight entry for the search index
public struct SessionIndexEntry: Sendable {
  public let sessionId: String
  public let projectPath: String
  public let slug: String
  public let gitBranch: String?
  public let firstMessage: String?
  public var summaries: [String]
  public let lastActivityAt: Date

  public init(
    sessionId: String,
    projectPath: String,
    slug: String,
    gitBranch: String?,
    firstMessage: String?,
    summaries: [String],
    lastActivityAt: Date
  ) {
    self.sessionId = sessionId
    self.projectPath = projectPath
    self.slug = slug
    self.gitBranch = gitBranch
    self.firstMessage = firstMessage
    self.summaries = summaries
    self.lastActivityAt = lastActivityAt
  }
}
