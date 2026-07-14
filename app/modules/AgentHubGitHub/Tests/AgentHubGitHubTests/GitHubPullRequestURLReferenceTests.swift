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

  @Test("Normalizes HTTPS and SSH GitHub remotes")
  func normalizesGitHubRemoteURLs() throws {
    let https = try #require(GitHubRepositoryIdentity(
      remoteURL: "https://github.com/JamesRochabrun/AgentHub.git"
    ))
    let scp = try #require(GitHubRepositoryIdentity(
      remoteURL: "git@github.com:jamesrochabrun/AgentHub.git"
    ))
    let ssh = try #require(GitHubRepositoryIdentity(
      remoteURL: "ssh://git@github.com/jamesrochabrun/AgentHub.git"
    ))

    #expect(https.owner == "JamesRochabrun")
    #expect(https.repository == "AgentHub")
    #expect(scp == GitHubRepositoryIdentity(owner: "jamesrochabrun", repository: "AgentHub"))
    #expect(ssh == scp)
    #expect(GitHubRepositoryIdentity(remoteURL: "https://gitlab.com/test/repo.git") == nil)
    #expect(GitHubRepositoryIdentity(remoteURL: "git@evilgithub.com:test/repo.git") == nil)
  }

  @Test("Selects the latest pull request for the resolved repository")
  func selectsLatestMatchingRepositoryReference() throws {
    let references = [
      "https://github.com/test/repo/pull/10",
      "https://github.com/other/repo/pull/99",
      "https://github.com/TEST/REPO/pull/11",
    ].compactMap(GitHubPullRequestURLReference.init(urlString:))

    let result = GitHubPullRequestURLReference.latest(
      matching: GitHubRepositoryIdentity(owner: "test", repository: "repo"),
      in: references
    )

    #expect(result?.number == 11)
  }
}
