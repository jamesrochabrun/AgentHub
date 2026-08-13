//
//  ContextProfileService.swift
//  AgentHub
//
//  CRUD for saved context profiles, plus the JSON index republish that keeps
//  the agent/CLI-visible mirror in sync with SQLite. Profiles are stored in
//  the app database only — never as files inside a user's repository.
//

import AgentHubCLIKit
import Foundation

public protocol ContextProfileServiceProtocol: Sendable {
  /// Profiles applicable to a project: its project-scoped profiles first,
  /// then personal (user-level) ones, each group name-ordered.
  func profiles(forProjectPath projectPath: String) async throws -> [ContextProfile]
  func save(_ profile: ContextProfile) async throws
  func delete(id: String, projectPath: String) async throws
  /// Marks a project-scoped profile as the project's default (nil clears it).
  func setDefault(id: String?, forProjectPath projectPath: String) async throws
  func defaultProfile(forProjectPath projectPath: String) async throws -> ContextProfile?
}

public actor ContextProfileService: ContextProfileServiceProtocol {

  private let metadataStore: SessionMetadataStore
  private let indexStore: ContextProfileIndexStore

  public init(
    metadataStore: SessionMetadataStore,
    indexStore: ContextProfileIndexStore = ContextProfileIndexStore()
  ) {
    self.metadataStore = metadataStore
    self.indexStore = indexStore
  }

  public func profiles(forProjectPath projectPath: String) async throws -> [ContextProfile] {
    let project = try await metadataStore.getContextProfiles(forProjectPath: projectPath)
    let personal = try await metadataStore.getPersonalContextProfiles()
    return (project + personal).compactMap { try? $0.decodedProfile() }
  }

  public func save(_ profile: ContextProfile) async throws {
    var stamped = profile
    stamped.updatedAt = Date()
    try await metadataStore.saveContextProfile(ContextProfileRecord(profile: stamped))
    await republish(afterMutationOf: stamped.scope, projectPath: stamped.projectPath)
  }

  public func delete(id: String, projectPath: String) async throws {
    let wasPersonal = try await metadataStore.getPersonalContextProfiles()
      .contains { $0.id == id }
    try await metadataStore.deleteContextProfile(id: id)
    await republish(afterMutationOf: wasPersonal ? .personal : .project, projectPath: projectPath)
  }

  public func setDefault(id: String?, forProjectPath projectPath: String) async throws {
    try await metadataStore.setDefaultContextProfile(id: id, forProjectPath: projectPath)
    await republish(afterMutationOf: .project, projectPath: projectPath)
  }

  public func defaultProfile(forProjectPath projectPath: String) async throws -> ContextProfile? {
    try await metadataStore.getContextProfiles(forProjectPath: projectPath)
      .first { $0.isDefault }
      .flatMap { try? $0.decodedProfile() }
  }

  /// Republishes a project's JSON index, mirroring to `aliasPaths` (worktree
  /// paths that resolve to this project) when the caller knows them.
  public func republishIndex(forProjectPath projectPath: String, aliasPaths: [String] = []) async {
    guard let allProfiles = try? await profiles(forProjectPath: projectPath) else { return }
    let key = MeasurementProjectScope.normalized(projectPath)
    let index = ContextProfileIndex(
      projectPath: key,
      updatedAt: Date(),
      profiles: allProfiles.map { profile in
        ContextProfileIndexEntry(
          id: profile.id,
          name: profile.name,
          scope: profile.scope.rawValue,
          isDefault: profile.isDefault,
          relativeFilePaths: profile.selection.files.map(\.relativePath),
          externalPaths: profile.selection.externalPaths,
          textSnippetTitles: profile.selection.textSnippets.map(\.title),
          instructions: profile.selection.instructions,
          updatedAt: profile.updatedAt
        )
      }
    )
    try? indexStore.write(index, aliasPaths: aliasPaths)
  }

  // MARK: - Private

  /// A project-scope mutation touches one index; a personal-scope mutation is
  /// visible from every project that has profiles, so all of them republish.
  private func republish(afterMutationOf scope: ContextProfileScope, projectPath: String) async {
    switch scope {
    case .project:
      await republishIndex(forProjectPath: projectPath)
    case .personal:
      let projectPaths = (try? await metadataStore.getProjectPathsWithContextProfiles()) ?? []
      for path in projectPaths {
        await republishIndex(forProjectPath: path)
      }
      if !projectPath.isEmpty {
        await republishIndex(forProjectPath: projectPath)
      }
    }
  }
}
