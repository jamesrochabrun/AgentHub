//
//  GitHubCLIServiceTests.swift
//  AgentHubTests
//
//  Parser tests for GitHubCLIService live gh output shapes
//

import Foundation
import Testing

@testable import AgentHubGitHub

@Suite("GitHubCLIService Parsing")
struct GitHubCLIServiceParsingTests {

  @Test("decodeCheckRuns accepts gh pr checks JSON fields")
  func decodeCheckRunsUsesSupportedFields() throws {
    let json = """
    [
      {
        "name": "Build",
        "state": "pending",
        "bucket": "pending",
        "link": "https://example.com/checks/1"
      }
    ]
    """

    let checks = try GitHubCLIService.decodeCheckRuns(json)

    #expect(checks.count == 1)
    #expect(checks[0].status == "pending")
    #expect(checks[0].bucket == "pending")
    #expect(checks[0].detailsUrl == "https://example.com/checks/1")
    #expect(checks[0].ciStatus == .pending)
    #expect(checks[0].statusDisplayName == "Pending")
  }

  @Test("maps unfinished and non-failing terminal check states accurately")
  func mapsExpandedCheckStates() {
    #expect(GitHubCheckRun(name: "Waiting", status: "WAITING").ciStatus == .pending)
    #expect(GitHubCheckRun(name: "Requested", status: "REQUESTED").ciStatus == .pending)
    #expect(GitHubCheckRun(name: "Expected", status: "EXPECTED").ciStatus == .pending)
    #expect(GitHubCheckRun(
      name: "Neutral",
      status: "COMPLETED",
      conclusion: "NEUTRAL"
    ).ciStatus == .none)
    #expect(GitHubCheckRun(
      name: "Skipped",
      status: "COMPLETED",
      conclusion: "SKIPPED"
    ).ciStatus == .none)
    #expect(GitHubCheckRun(
      name: "Action",
      status: "COMPLETED",
      conclusion: "ACTION_REQUIRED"
    ).ciStatus == .failure)
  }

  @Test("decodes workflow rollup metadata with stable check identity")
  func decodesWorkflowRollupMetadata() throws {
    let json = """
    {
      "name": "test",
      "status": "COMPLETED",
      "conclusion": "SUCCESS",
      "detailsUrl": "https://github.com/test/repo/actions/runs/1/job/2",
      "workflowName": "Tests",
      "startedAt": "2026-07-12T05:38:49Z",
      "completedAt": "2026-07-12T05:40:03Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let check = try decoder.decode(GitHubCheckRun.self, from: Data(json.utf8))

    #expect(check.workflowName == "Tests")
    #expect(check.startedAt != nil)
    #expect(check.completedAt != nil)
    #expect(check.id == "Tests|test|https://github.com/test/repo/actions/runs/1/job/2")
  }

  @Test("current branch no-PR message is recognized")
  func currentBranchNoPRMessageIsRecognized() {
    #expect(GitHubCLIService.isNoCurrentBranchPRMessage(
      #"no pull requests found for branch "github-observe""#
    ))
    #expect(!GitHubCLIService.isNoCurrentBranchPRMessage("authentication required"))
  }

  @Test("no checks reported message is recognized")
  func noChecksReportedMessageIsRecognized() {
    #expect(GitHubCLIService.isNoChecksReportedMessage(
      "no checks reported on the 'drag-arrange' branch"
    ))
    #expect(!GitHubCLIService.isNoChecksReportedMessage("authentication required"))
  }

  @Test("parsePRFiles handles slurped paginated arrays")
  func parsePRFilesHandlesSlurpedPages() throws {
    let json = """
    [
      [
        {
          "filename": "Sources/FileA.swift",
          "status": "modified",
          "additions": 5,
          "deletions": 2,
          "patch": "@@ -1 +1 @@\\n-old\\n+new"
        }
      ],
      [
        {
          "filename": "Sources/FileB.swift",
          "status": "added",
          "additions": 10,
          "deletions": 0,
          "patch": "@@ -0,0 +1 @@\\n+hello"
        }
      ]
    ]
    """

    let files = try GitHubCLIService.parsePRFiles(json, fallbackFilenames: [])

    #expect(files.map(\.filename) == ["Sources/FileA.swift", "Sources/FileB.swift"])
    #expect(files[0].status == "modified")
    #expect(files[1].status == "added")
  }

  @Test("parseReviewComments handles slurped paginated arrays")
  func parseReviewCommentsHandlesSlurpedPages() throws {
    let json = """
    [
      [
        {
          "id": 1,
          "user": { "login": "octocat" },
          "body": "Looks good",
          "created_at": "2026-03-25T20:30:00.123Z",
          "path": "Sources/FileA.swift",
          "line": 12,
          "diff_hunk": "@@ -10 +12 @@"
        }
      ],
      [
        {
          "id": 2,
          "user": { "login": "hubot" },
          "body": "Please rename this",
          "created_at": "2026-03-25T20:31:00.123Z",
          "path": "Sources/FileB.swift",
          "line": 4,
          "diff_hunk": "@@ -4 +4 @@"
        }
      ]
    ]
    """

    let comments = try GitHubCLIService.parseReviewComments(json)

    #expect(comments.count == 2)
    #expect(comments[0].author?.login == "octocat")
    #expect(comments[1].author?.login == "hubot")
    #expect(comments[1].path == "Sources/FileB.swift")
  }
}
