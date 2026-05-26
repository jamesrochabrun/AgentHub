//
//  GitHubPullRequestURLReference.swift
//  AgentHubGitHub
//
//  Lightweight parser for GitHub pull request URLs detected in session output.
//

import Foundation

public struct GitHubPullRequestURLReference: Equatable, Sendable {
  public let owner: String
  public let repository: String
  public let number: Int
  public let url: String

  public init?(urlString: String) {
    guard let components = URLComponents(string: urlString),
          let host = components.host?.lowercased(),
          host == "github.com" || host == "www.github.com" else {
      return nil
    }

    let parts = components.path
      .split(separator: "/", omittingEmptySubsequences: true)
      .map(String.init)

    guard parts.count >= 4,
          parts[2] == "pull",
          let number = Int(parts[3]) else {
      return nil
    }

    self.owner = parts[0]
    self.repository = parts[1]
    self.number = number
    self.url = urlString
  }

  public static func latest(in urls: [String]) -> GitHubPullRequestURLReference? {
    urls.compactMap(GitHubPullRequestURLReference.init(urlString:)).last
  }

  public static func latestNumber(in urls: [String]) -> Int? {
    latest(in: urls)?.number
  }
}
