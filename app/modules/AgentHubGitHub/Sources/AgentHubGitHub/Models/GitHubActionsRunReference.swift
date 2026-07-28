//
//  GitHubActionsRunReference.swift
//  AgentHub
//
//  Parses GitHub Actions run/job identity out of check-run details URLs
//

import Foundation

/// A workflow run (and optionally job) referenced by a check run's `detailsUrl`.
///
/// GitHub Actions check runs report URLs shaped like
/// `https://github.com/{owner}/{repo}/actions/runs/{runId}/job/{jobId}?pr=1`.
/// External CI systems report arbitrary URLs, which parse to `nil`.
public struct GitHubActionsRunReference: Equatable, Sendable {
  public let runId: String
  public let jobId: String?

  public init(runId: String, jobId: String? = nil) {
    self.runId = runId
    self.jobId = jobId
  }

  public init?(detailsUrl: String?) {
    guard let detailsUrl, let url = URL(string: detailsUrl) else { return nil }
    let components = url.pathComponents
    guard
      let actionsIndex = components.firstIndex(of: "actions"),
      components.indices.contains(actionsIndex + 2),
      components[actionsIndex + 1] == "runs",
      Self.isIdentifier(components[actionsIndex + 2])
    else { return nil }

    runId = components[actionsIndex + 2]
    if let jobIndex = components.firstIndex(of: "job"),
       jobIndex > actionsIndex,
       components.indices.contains(jobIndex + 1),
       Self.isIdentifier(components[jobIndex + 1]) {
      jobId = components[jobIndex + 1]
    } else {
      jobId = nil
    }
  }

  private static func isIdentifier(_ component: String) -> Bool {
    !component.isEmpty && component.allSatisfy(\.isNumber)
  }
}
