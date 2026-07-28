//
//  GitHubCIFixTests.swift
//  AgentHubTests
//
//  Tests for CI failure run parsing, fix prompt composition, and log fetching
//

import Foundation
import Testing

@testable import AgentHubGitHub

// MARK: - GitHubActionsRunReference

@Suite("GitHubActionsRunReference")
struct GitHubActionsRunReferenceTests {

  @Test("parses run and job ids from an Actions job URL")
  func parsesRunAndJobIds() {
    let reference = GitHubActionsRunReference(
      detailsUrl: "https://github.com/owner/repo/actions/runs/16543219876/job/46781234567?pr=42"
    )
    #expect(reference?.runId == "16543219876")
    #expect(reference?.jobId == "46781234567")
  }

  @Test("parses a run-only Actions URL without a job component")
  func parsesRunOnlyURL() {
    let reference = GitHubActionsRunReference(
      detailsUrl: "https://github.com/owner/repo/actions/runs/123456"
    )
    #expect(reference?.runId == "123456")
    #expect(reference?.jobId == nil)
  }

  @Test("rejects non-Actions and malformed URLs")
  func rejectsNonActionsURLs() {
    #expect(GitHubActionsRunReference(detailsUrl: "https://circleci.com/gh/owner/repo/123") == nil)
    #expect(GitHubActionsRunReference(detailsUrl: "https://github.com/owner/repo/pull/12") == nil)
    #expect(GitHubActionsRunReference(detailsUrl: "https://github.com/owner/repo/actions/runs/not-a-number") == nil)
    #expect(GitHubActionsRunReference(detailsUrl: nil) == nil)
    #expect(GitHubActionsRunReference(detailsUrl: "") == nil)
  }
}

// MARK: - GitHubCIFixPromptBuilder

@Suite("GitHubCIFixPromptBuilder")
struct GitHubCIFixPromptBuilderTests {

  @Test("prompt includes PR context, failed checks, and log excerpts")
  func promptIncludesContextChecksAndLogs() {
    let prompt = GitHubCIFixPromptBuilder.prompt(
      prNumber: 42,
      prTitle: "Add CI notifications",
      branchName: "jroch-ci",
      failedChecks: [
        GitHubCIFixPromptBuilder.FailedCheck(
          name: "test",
          workflowName: "Tests",
          detailsUrl: "https://github.com/owner/repo/actions/runs/99/job/1"
        )
      ],
      logExcerpts: [
        GitHubCIFixPromptBuilder.LogExcerpt(runId: "99", text: "error: test 'foo' failed")
      ]
    )

    #expect(prompt.contains("PR #42"))
    #expect(prompt.contains("Add CI notifications"))
    #expect(prompt.contains("`jroch-ci`"))
    #expect(prompt.contains("Tests / test — https://github.com/owner/repo/actions/runs/99/job/1"))
    #expect(prompt.contains("gh run view 99 --log-failed"))
    #expect(prompt.contains("error: test 'foo' failed"))
    #expect(prompt.contains("push the fix"))
  }

  @Test("prompt without logs points the agent at gh commands")
  func promptWithoutLogsMentionsGHFallback() {
    let prompt = GitHubCIFixPromptBuilder.prompt(
      prNumber: 7,
      prTitle: nil,
      branchName: nil,
      failedChecks: [GitHubCIFixPromptBuilder.FailedCheck(name: "lint")],
      logExcerpts: []
    )

    #expect(prompt.contains("gh pr checks 7"))
    #expect(prompt.contains("--log-failed"))
    #expect(prompt.contains("- lint"))
  }

  @Test("truncatedLogTail keeps the tail and annotates truncation")
  func truncatedLogTailKeepsTail() {
    let log = (1...400).map { "line \($0): some CI output" }.joined(separator: "\n")
    let excerpt = GitHubCIFixPromptBuilder.truncatedLogTail(log, maximumCharacters: 500)

    #expect(excerpt.count < log.count)
    #expect(excerpt.hasPrefix("… (log truncated"))
    #expect(excerpt.contains("line 400: some CI output"))
    #expect(!excerpt.contains("line 1: some CI output\nline 2"))
  }

  @Test("truncatedLogTail returns short logs unchanged")
  func truncatedLogTailShortLogUnchanged() {
    #expect(GitHubCIFixPromptBuilder.truncatedLogTail("  error: boom\n") == "error: boom")
  }
}

// MARK: - GitHubCIFixService

@Suite("GitHubCIFixService")
struct GitHubCIFixServiceTests {

  private func makeFailedCheck(
    name: String,
    runId: String? = nil
  ) -> GitHubCIFixPromptBuilder.FailedCheck {
    GitHubCIFixPromptBuilder.FailedCheck(
      name: name,
      workflowName: "CI",
      detailsUrl: runId.map { "https://github.com/owner/repo/actions/runs/\($0)/job/1" }
    )
  }

  @Test("fetches logs once per unique run id and embeds the excerpt")
  func fetchesLogsPerUniqueRun() async {
    let mock = MockGitHubCLIService()
    mock.failedRunLogsResult = "assertion failed: expected 2 got 3"
    let service = GitHubCIFixService(service: mock)

    let prompt = await service.buildFixPrompt(
      projectPath: "/tmp/repo",
      prNumber: 12,
      prTitle: "Fix things",
      branchName: "feature",
      failedChecks: [
        makeFailedCheck(name: "build", runId: "555"),
        makeFailedCheck(name: "test", runId: "555"),
      ]
    )

    #expect(mock.getFailedRunLogsCallCount == 1)
    #expect(mock.getFailedRunLogsRunIds == ["555"])
    #expect(mock.getFailedRunLogsRepoPath == "/tmp/repo")
    #expect(prompt.contains("assertion failed: expected 2 got 3"))
  }

  @Test("caps log fetches at the configured maximum")
  func capsLogFetches() async {
    let mock = MockGitHubCLIService()
    mock.failedRunLogsResult = "log"
    let service = GitHubCIFixService(service: mock, maximumRunLogFetches: 2)

    _ = await service.buildFixPrompt(
      projectPath: "/tmp/repo",
      prNumber: 1,
      prTitle: nil,
      branchName: nil,
      failedChecks: [
        makeFailedCheck(name: "a", runId: "1"),
        makeFailedCheck(name: "b", runId: "2"),
        makeFailedCheck(name: "c", runId: "3"),
      ]
    )

    #expect(mock.getFailedRunLogsRunIds == ["1", "2"])
  }

  @Test("log fetch failure still produces a prompt with gh guidance")
  func degradesWhenLogFetchFails() async {
    let mock = MockGitHubCLIService()
    mock.errorToThrow = GitHubCLIError.timeout
    let service = GitHubCIFixService(service: mock)

    let prompt = await service.buildFixPrompt(
      projectPath: "/tmp/repo",
      prNumber: 9,
      prTitle: nil,
      branchName: "feature",
      failedChecks: [makeFailedCheck(name: "test", runId: "77")]
    )

    #expect(prompt.contains("CI is failing on PR #9"))
    #expect(prompt.contains("Log output could not be fetched automatically"))
  }

  @Test("checks without Actions URLs skip log fetching entirely")
  func skipsLogFetchForExternalChecks() async {
    let mock = MockGitHubCLIService()
    let service = GitHubCIFixService(service: mock)

    let prompt = await service.buildFixPrompt(
      projectPath: "/tmp/repo",
      prNumber: 3,
      prTitle: nil,
      branchName: nil,
      failedChecks: [GitHubCIFixPromptBuilder.FailedCheck(name: "external-ci", detailsUrl: "https://ci.example.com/build/9")]
    )

    #expect(mock.getFailedRunLogsCallCount == 0)
    #expect(prompt.contains("external-ci — https://ci.example.com/build/9"))
  }
}
