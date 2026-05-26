import Testing

@testable import AgentHubGitHub

@Suite("GitHubPullRequestURLReference")
struct GitHubPullRequestURLReferenceTests {

  @Test("Parses GitHub pull request URLs")
  func parsesPullRequestURLs() throws {
    let reference = try #require(GitHubPullRequestURLReference(
      urlString: "https://github.com/jamesrochabrun/AgentHub/pull/322"
    ))

    #expect(reference.owner == "jamesrochabrun")
    #expect(reference.repository == "AgentHub")
    #expect(reference.number == 322)
  }

  @Test("Returns latest pull request URL from resource list")
  func returnsLatestPullRequestURL() {
    let number = GitHubPullRequestURLReference.latestNumber(in: [
      "https://example.com/page",
      "https://github.com/jamesrochabrun/AgentHub/pull/321",
      "https://github.com/jamesrochabrun/AgentHub/pull/322"
    ])

    #expect(number == 322)
  }

  @Test("Ignores non pull request URLs")
  func ignoresNonPullRequestURLs() {
    #expect(GitHubPullRequestURLReference(urlString: "https://github.com/jamesrochabrun/AgentHub/issues/322") == nil)
    #expect(GitHubPullRequestURLReference(urlString: "https://avatars.githubusercontent.com/u/5378604") == nil)
  }
}
