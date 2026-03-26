//
//  SessionGitHubQuickAccessViewModel.swift
//  AgentHub
//
//  Lightweight GitHub state for session card quick access
//

import Foundation

@MainActor
@Observable
public final class SessionGitHubQuickAccessViewModel {

  public private(set) var currentBranchPR: GitHubPullRequest?

  private let service: any GitHubCLIServiceProtocol
  private var loadedRepositoryKey: String?

  public init(service: any GitHubCLIServiceProtocol = GitHubCLIService()) {
    self.service = service
  }

  public func load(projectPath: String, branchName: String?) async {
    let repositoryKey = Self.repositoryKey(projectPath: projectPath, branchName: branchName)
    guard loadedRepositoryKey != repositoryKey else { return }

    loadedRepositoryKey = repositoryKey
    currentBranchPR = nil

    guard await service.isInstalled() else { return }
    guard !Task.isCancelled else { return }
    guard await service.isAuthenticated(at: projectPath) else { return }
    guard !Task.isCancelled else { return }

    do {
      let pullRequest = try await service.getCurrentBranchPR(at: projectPath)
      guard !Task.isCancelled, loadedRepositoryKey == repositoryKey else { return }
      currentBranchPR = pullRequest
    } catch {
      guard !Task.isCancelled, loadedRepositoryKey == repositoryKey else { return }
      currentBranchPR = nil
    }
  }

  static func repositoryKey(projectPath: String, branchName: String?) -> String {
    "\(projectPath)|\(branchName ?? "")"
  }
}
