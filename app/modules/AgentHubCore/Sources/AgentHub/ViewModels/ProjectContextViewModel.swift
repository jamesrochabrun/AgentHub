//
//  ProjectContextViewModel.swift
//  AgentHub
//
//  Drives the Project Details Context tab: the project's saved context
//  profiles (project + personal scope), per-profile token estimates, and the
//  panel's first editing actions (delete, set default).
//

import Foundation
import Observation

@MainActor
@Observable
public final class ProjectContextViewModel {

  private let service: (any ContextProfileServiceProtocol)?
  private let fileLoader: any ContextFileLoading
  private let estimator: any ContextTokenEstimating

  public let projectPath: String
  public private(set) var profiles: [ContextProfile] = []
  /// Approximate token cost per profile id, for the card badge.
  public private(set) var estimatedTokensByProfileId: [String: Int] = [:]
  public private(set) var isLoading = false
  public var lastActionError: String?

  public var isAvailable: Bool { service != nil }
  var profileService: (any ContextProfileServiceProtocol)? { service }
  var contextFileLoader: any ContextFileLoading { fileLoader }

  public init(
    projectPath: String,
    service: (any ContextProfileServiceProtocol)?,
    fileLoader: any ContextFileLoading = ContextFileLoader(),
    estimator: any ContextTokenEstimating = ContextTokenEstimator()
  ) {
    self.projectPath = projectPath
    self.service = service
    self.fileLoader = fileLoader
    self.estimator = estimator
  }

  public func load() async {
    guard let service else { return }
    isLoading = true
    defer { isLoading = false }
    profiles = (try? await service.profiles(forProjectPath: projectPath)) ?? []
    await refreshEstimates()
  }

  public func delete(_ profile: ContextProfile) async {
    guard let service else { return }
    do {
      try await service.delete(id: profile.id, projectPath: projectPath)
      lastActionError = nil
    } catch {
      lastActionError = "Could not delete “\(profile.name)”."
    }
    await load()
  }

  /// Marks `profile` as the project default; pass nil to clear it.
  public func setDefault(_ profile: ContextProfile?) async {
    guard let service else { return }
    do {
      try await service.setDefault(id: profile?.id, forProjectPath: projectPath)
      lastActionError = nil
    } catch {
      lastActionError = "Only a project-scoped profile can be the default."
    }
    await load()
  }

  private func refreshEstimates() async {
    var estimates: [String: Int] = [:]
    for profile in profiles {
      let metrics = await fileLoader.fileMetrics(
        relativePaths: profile.selection.files.map(\.relativePath),
        projectPath: projectPath
      )
      let externalStatuses = await fileLoader.externalFileStatuses(
        absolutePaths: profile.selection.externalPaths
      )
      var tokens = metrics.values.reduce(0) {
        $0 + estimator.estimatedTokens(forByteCount: $1.byteCount)
      }
      for status in externalStatuses.values {
        if case .text(let fileMetrics) = status {
          tokens += estimator.estimatedTokens(forByteCount: fileMetrics.byteCount)
        }
      }
      let snippetTokens = profile.selection.textSnippets.reduce(0) {
        $0 + estimator.estimatedTokens(forByteCount: $1.content.utf8.count)
      }
      estimates[profile.id] =
        tokens + snippetTokens
        + estimator.estimatedTokens(forByteCount: profile.selection.instructions.utf8.count)
    }
    estimatedTokensByProfileId = estimates
  }
}
