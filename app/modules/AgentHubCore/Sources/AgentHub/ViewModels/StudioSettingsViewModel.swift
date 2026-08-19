//
//  StudioSettingsViewModel.swift
//  AgentHub
//
//  Backs the Settings tab for reviewing and deleting stored Studio artifacts.
//

import AgentHubCLIKit
import Foundation

/// Lists and deletes stored Studio artifacts, grouped by project.
///
/// Settings exists for what the panel cannot reach: the panel only shows the
/// project of a session you currently have open, so artifacts for a repository
/// you have since removed are otherwise invisible and permanent. Grouped by
/// project, never by worktree — worktrees roll up to their parent repo.
@MainActor
@Observable
public final class StudioSettingsViewModel {
  public private(set) var projects: [StudioLibrary.ProjectSummary] = []
  public private(set) var isLoading = false

  private let library: StudioLibrary?

  public init(library: StudioLibrary?) {
    self.library = library
  }

  public var isEmpty: Bool { projects.isEmpty }

  public var totalCount: Int {
    projects.reduce(0) { $0 + $1.artifacts.count }
  }

  public var totalBytes: Int64 {
    projects.reduce(0) { $0 + $1.bytesOnDisk }
  }

  public func load() async {
    guard let library else { return }
    isLoading = true
    defer { isLoading = false }
    projects = await library.allProjects()
  }

  public func delete(id: String, inProjectKey key: String) async {
    guard let library else { return }
    await library.delete(id: id, projectKey: key, aliasPaths: [])
    await load()
  }

  public func deleteAll(inProjectKey key: String) async {
    guard let library else { return }
    await library.deleteAll(projectKey: key)
    await load()
  }

  public static func displayName(forProjectKey key: String) -> String {
    let name = (key as NSString).lastPathComponent
    return name.isEmpty ? key : name
  }
}
