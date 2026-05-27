import AgentHubCLIKit
import Foundation

@MainActor
public protocol WorktreeLaunchRequestHandlingProtocol: AnyObject {
  func handle(_ request: WorktreeLaunchRequest) async throws
}

enum WorktreeLaunchRequestHandlingError: LocalizedError {
  case providerUnavailable
  case emptyPrompt

  var errorDescription: String? {
    switch self {
    case .providerUnavailable:
      return "AgentHub provider is unavailable."
    case .emptyPrompt:
      return "The queued worktree launch request did not include a prompt."
    }
  }
}

@MainActor
public final class WorktreeLaunchRequestHandler: WorktreeLaunchRequestHandlingProtocol {
  private let claudeViewModel: CLISessionsViewModel
  private let codexViewModel: CLISessionsViewModel

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
  }

  public func handle(_ request: WorktreeLaunchRequest) async throws {
    let prompt = WorktreeLaunchPromptSanitizer.launchedTaskPrompt(
      from: request.prompt,
      branchName: request.branchName
    )
    guard !prompt.isEmpty else {
      throw WorktreeLaunchRequestHandlingError.emptyPrompt
    }

    let viewModel: CLISessionsViewModel
    switch request.provider {
    case .claude:
      viewModel = claudeViewModel
    case .codex:
      viewModel = codexViewModel
    }

    let worktree = await viewModel.registerCreatedWorktree(
      name: request.branchName,
      path: request.worktreePath,
      parentRepositoryPath: request.repositoryPath
    )
    viewModel.startNewSessionInHub(worktree, initialPrompt: prompt)
    viewModel.refresh()
  }
}

enum WorktreeLaunchPromptSanitizer {
  static func launchedTaskPrompt(from prompt: String, branchName: String) -> String {
    let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if let extracted = extractedTask(from: trimmed) {
      return extracted
    }

    if isLikelyWorktreeOrchestrationPrompt(trimmed) {
      return readableTaskPrompt(from: branchName)
    }

    return trimmed
  }

  private static func extractedTask(from prompt: String) -> String? {
    let patterns = [
      #"^\s*(?:please\s+)?(?:create|make|start|launch|spin\s+up)\s+(?:one\s+|onw\s+|a\s+|an\s+|new\s+)?(?:agenthub\s+)?worktree\s+(?:for|to|because|so\s+i\s+can|i\s+have\s+to)\s+(.+)$"#,
      #"^\s*(?:please\s+)?(?:create|make|start|launch|spin\s+up)\s+(?:one\s+|onw\s+|a\s+|an\s+|new\s+)?(?:agenthub\s+)?(?:agent|session)\s+(?:for|to)\s+(.+)$"#
    ]

    for pattern in patterns {
      guard let match = firstCapture(in: prompt, pattern: pattern) else { continue }
      let extracted = match.trimmingCharacters(in: .whitespacesAndNewlines)
      if !extracted.isEmpty {
        return extracted
      }
    }
    return nil
  }

  private static func isLikelyWorktreeOrchestrationPrompt(_ prompt: String) -> Bool {
    let lowercased = prompt.lowercased()
    let hasCreateVerb = [
      "create",
      "make",
      "start",
      "launch",
      "spin up"
    ].contains { lowercased.contains($0) }
    let hasLaunchTarget = [
      "worktree",
      "agent",
      "session"
    ].contains { lowercased.contains($0) }
    return hasCreateVerb && hasLaunchTarget
  }

  private static func readableTaskPrompt(from branchName: String) -> String {
    let task = branchName
      .replacingOccurrences(of: "/", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return task.isEmpty ? "" : "Work on \(task)."
  }

  private static func firstCapture(in value: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }

    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = regex.firstMatch(in: value, range: range),
          match.numberOfRanges > 1,
          let captureRange = Range(match.range(at: 1), in: value) else {
      return nil
    }
    return String(value[captureRange])
  }
}
