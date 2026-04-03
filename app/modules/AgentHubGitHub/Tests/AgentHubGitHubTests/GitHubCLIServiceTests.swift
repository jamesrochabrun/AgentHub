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
