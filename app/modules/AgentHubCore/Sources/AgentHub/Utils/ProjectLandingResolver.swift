//
//  ProjectLandingResolver.swift
//  AgentHub
//

import Foundation

/// Resolves the repository that should own the recently-added project landing.
public enum ProjectLandingResolver {
  public static func landingPath(
    for addedPath: String,
    repositories: [SelectedRepository]
  ) -> String {
    resolvedRepository(for: addedPath, repositories: repositories)?.path ?? addedPath
  }

  public static func resolvedRepository(
    for addedPath: String,
    repositories: [SelectedRepository]
  ) -> SelectedRepository? {
    let rootPath = ProjectHierarchyResolver.rootProjectPath(
      for: addedPath,
      repositories: repositories
    )
    return repositories.first { $0.path == rootPath }
  }
}
