import Foundation
import Testing

@testable import AgentHubCore

@Suite("GitHubContextDragPayload")
struct GitHubContextDragPayloadTests {

  @Test("Pull request payload formats review command")
  func pullRequestPayloadFormatsReviewCommand() {
    let payload = GitHubContextDragPayload(
      kind: .pullRequest,
      number: 42,
      title: "Add drag support",
      url: "https://github.com/example/repo/pull/42"
    )

    #expect(payload.commandText == "/review https://github.com/example/repo/pull/42")
  }

  @Test("Issue payload formats fix command")
  func issuePayloadFormatsFixCommand() {
    let payload = GitHubContextDragPayload(
      kind: .issue,
      number: 7,
      title: "Fix login state",
      url: "https://github.com/example/repo/issues/7"
    )

    #expect(payload.commandText == "fix https://github.com/example/repo/issues/7")
  }

  @Test("Payload round trips through JSON")
  func payloadRoundTripsThroughJSON() throws {
    let payload = GitHubContextDragPayload(
      kind: .pullRequest,
      number: 108,
      title: "Review panel drag payload",
      url: "https://github.com/example/repo/pull/108"
    )

    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(GitHubContextDragPayload.self, from: data)

    #expect(decoded == payload)
  }
}
