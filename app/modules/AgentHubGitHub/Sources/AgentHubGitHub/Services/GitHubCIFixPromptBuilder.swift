//
//  GitHubCIFixPromptBuilder.swift
//  AgentHub
//
//  Composes the "Fix CI" prompt sent to a session's agent terminal
//

import Foundation

/// Builds the prompt injected into an agent session when the user asks
/// AgentHub to fix a failing CI run.
public enum GitHubCIFixPromptBuilder {

  public struct FailedCheck: Equatable, Sendable {
    public let name: String
    public let workflowName: String?
    public let detailsUrl: String?

    public init(name: String, workflowName: String? = nil, detailsUrl: String? = nil) {
      self.name = name
      self.workflowName = workflowName
      self.detailsUrl = detailsUrl
    }

    public init(check: GitHubCheckRun) {
      self.init(name: check.name, workflowName: check.workflowName, detailsUrl: check.detailsUrl)
    }

    public var displayName: String {
      guard let workflowName, !workflowName.isEmpty, workflowName != name else { return name }
      return "\(workflowName) / \(name)"
    }
  }

  public struct LogExcerpt: Equatable, Sendable {
    public let runId: String
    public let text: String

    public init(runId: String, text: String) {
      self.runId = runId
      self.text = text
    }
  }

  /// Keeps injected prompts small enough for a terminal paste while retaining
  /// the failure tail, where build/test errors actually appear.
  public static let defaultMaximumLogCharacters = 6_000

  public static func prompt(
    prNumber: Int,
    prTitle: String?,
    branchName: String?,
    failedChecks: [FailedCheck],
    logExcerpts: [LogExcerpt]
  ) -> String {
    var lines: [String] = []
    var headline = "CI is failing on PR #\(prNumber)"
    if let prTitle, !prTitle.isEmpty {
      headline += " (\"\(prTitle)\")"
    }
    if let branchName, !branchName.isEmpty {
      headline += " for branch `\(branchName)`"
    }
    lines.append(headline + ".")

    if !failedChecks.isEmpty {
      lines.append("")
      lines.append("Failed checks:")
      for check in failedChecks {
        if let detailsUrl = check.detailsUrl, !detailsUrl.isEmpty {
          lines.append("- \(check.displayName) — \(detailsUrl)")
        } else {
          lines.append("- \(check.displayName)")
        }
      }
    }

    if logExcerpts.isEmpty {
      lines.append("")
      lines.append(
        "Log output could not be fetched automatically. Run `gh pr checks \(prNumber)` and `gh run view <run-id> --log-failed` (or open the check URLs above) to inspect the failure."
      )
    } else {
      for excerpt in logExcerpts {
        lines.append("")
        lines.append("Failing step logs from `gh run view \(excerpt.runId) --log-failed`:")
        lines.append("```")
        lines.append(excerpt.text)
        lines.append("```")
      }
    }

    lines.append("")
    lines.append(
      "Diagnose the CI failure, fix the underlying issue, run the relevant local tests to confirm, and push the fix to this PR's branch. If you need more log context, run `gh run view <run-id> --log-failed`."
    )
    return lines.joined(separator: "\n")
  }

  /// Returns the tail of a CI log, annotated when truncation occurred.
  public static func truncatedLogTail(
    _ log: String,
    maximumCharacters: Int = defaultMaximumLogCharacters
  ) -> String {
    let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maximumCharacters else { return trimmed }
    var tail = String(trimmed.suffix(maximumCharacters))
    if let firstNewline = tail.firstIndex(of: "\n") {
      // Drop the likely-partial first line so the excerpt starts clean.
      tail = String(tail[tail.index(after: firstNewline)...])
    }
    return "… (log truncated, showing the last \(tail.count) of \(trimmed.count) characters)\n" + tail
  }
}
