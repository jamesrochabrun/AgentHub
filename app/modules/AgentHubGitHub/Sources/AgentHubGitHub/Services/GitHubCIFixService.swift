//
//  GitHubCIFixService.swift
//  AgentHub
//
//  Fetches failing CI logs and builds the agent-facing fix prompt
//

import Foundation

// MARK: - GitHubCIFixServiceProtocol

public protocol GitHubCIFixServiceProtocol: AnyObject, Sendable {
  /// Builds the prompt for an agent to fix the failing checks of a PR,
  /// fetching failed-run logs when the checks reference GitHub Actions runs.
  /// Never throws — log fetch failures degrade to a prompt without logs.
  func buildFixPrompt(
    projectPath: String,
    prNumber: Int,
    prTitle: String?,
    branchName: String?,
    failedChecks: [GitHubCIFixPromptBuilder.FailedCheck]
  ) async -> String
}

// MARK: - GitHubCIFixService

public actor GitHubCIFixService: GitHubCIFixServiceProtocol {

  private let service: any GitHubCLIServiceProtocol
  private let maximumRunLogFetches: Int
  private let maximumLogCharacters: Int

  public init(
    service: any GitHubCLIServiceProtocol = GitHubCLIService(),
    maximumRunLogFetches: Int = 2,
    maximumLogCharacters: Int = GitHubCIFixPromptBuilder.defaultMaximumLogCharacters
  ) {
    self.service = service
    self.maximumRunLogFetches = max(0, maximumRunLogFetches)
    self.maximumLogCharacters = maximumLogCharacters
  }

  public func buildFixPrompt(
    projectPath: String,
    prNumber: Int,
    prTitle: String?,
    branchName: String?,
    failedChecks: [GitHubCIFixPromptBuilder.FailedCheck]
  ) async -> String {
    var runIds: [String] = []
    for check in failedChecks {
      guard let reference = GitHubActionsRunReference(detailsUrl: check.detailsUrl) else { continue }
      if !runIds.contains(reference.runId) {
        runIds.append(reference.runId)
      }
    }

    var logExcerpts: [GitHubCIFixPromptBuilder.LogExcerpt] = []
    for runId in runIds.prefix(maximumRunLogFetches) {
      guard let log = try? await service.getFailedRunLogs(runId: runId, at: projectPath) else { continue }
      let excerpt = GitHubCIFixPromptBuilder.truncatedLogTail(log, maximumCharacters: maximumLogCharacters)
      if !excerpt.isEmpty {
        logExcerpts.append(GitHubCIFixPromptBuilder.LogExcerpt(runId: runId, text: excerpt))
      }
    }

    return GitHubCIFixPromptBuilder.prompt(
      prNumber: prNumber,
      prTitle: prTitle,
      branchName: branchName,
      failedChecks: failedChecks,
      logExcerpts: logExcerpts
    )
  }
}
