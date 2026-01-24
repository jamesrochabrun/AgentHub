//
//  GitHubRepository.swift
//  AgentHub
//
//  Model for GitHub repository data
//

import Foundation

/// Represents a GitHub repository
public struct GitHubRepository: Sendable, Codable, Identifiable, Hashable {
  /// Unique repository ID from GitHub
  public let id: Int

  /// Repository name (e.g., "AgentHub")
  public let name: String

  /// Full repository name including owner (e.g., "user/AgentHub")
  public let fullName: String

  /// URL to the repository on GitHub (e.g., "https://github.com/user/AgentHub")
  public let htmlUrl: String

  /// Git clone URL (e.g., "https://github.com/user/AgentHub.git")
  public let cloneUrl: String

  /// Optional repository description
  public let description: String?

  /// Whether the repository is private
  public let isPrivate: Bool

  public init(
    id: Int,
    name: String,
    fullName: String,
    htmlUrl: String,
    cloneUrl: String,
    description: String?,
    isPrivate: Bool
  ) {
    self.id = id
    self.name = name
    self.fullName = fullName
    self.htmlUrl = htmlUrl
    self.cloneUrl = cloneUrl
    self.description = description
    self.isPrivate = isPrivate
  }

  // MARK: - CodingKeys

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case fullName = "full_name"
    case htmlUrl = "html_url"
    case cloneUrl = "clone_url"
    case description
    case isPrivate = "private"
  }
}
