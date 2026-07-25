import Testing

@testable import AgentHubGitHub

/// Serialized: the suite asserts on shared cache occupancy.
@Suite("GitHubPullRequestURLReferenceCache", .serialized)
@MainActor
struct GitHubPullRequestURLReferenceCacheTests {

  @Test("Returns the same result as direct parsing")
  func matchesDirectParsing() {
    GitHubPullRequestURLReferenceCache.resetForTesting()

    let urls = [
      "https://github.com/jamesrochabrun/AgentHub/pull/322",
      "https://www.github.com/owner/repo/pull/7",
      "https://github.com/jamesrochabrun/AgentHub/issues/322",
      "https://example.com/page",
      "not a url at all"
    ]

    for url in urls {
      #expect(
        GitHubPullRequestURLReferenceCache.reference(for: url)
          == GitHubPullRequestURLReference(urlString: url)
      )
    }
  }

  @Test("Repeated lookups are served from one cached entry")
  func repeatedLookupsReuseEntry() throws {
    GitHubPullRequestURLReferenceCache.resetForTesting()
    let url = "https://github.com/jamesrochabrun/AgentHub/pull/322"

    let first = try #require(GitHubPullRequestURLReferenceCache.reference(for: url))
    #expect(GitHubPullRequestURLReferenceCache.cachedEntryCount == 1)

    for _ in 0..<50 {
      #expect(GitHubPullRequestURLReferenceCache.reference(for: url) == first)
    }
    #expect(GitHubPullRequestURLReferenceCache.cachedEntryCount == 1)
  }

  @Test("Caches non-PR URLs so they are not re-parsed")
  func cachesNegativeResults() {
    GitHubPullRequestURLReferenceCache.resetForTesting()

    #expect(GitHubPullRequestURLReferenceCache.reference(for: "https://example.com/page") == nil)
    #expect(GitHubPullRequestURLReferenceCache.cachedEntryCount == 1)
    #expect(GitHubPullRequestURLReferenceCache.reference(for: "https://example.com/page") == nil)
    #expect(GitHubPullRequestURLReferenceCache.cachedEntryCount == 1)
  }

  @Test("references(in:) preserves order and drops non-PR URLs")
  func referencesPreserveOrder() {
    GitHubPullRequestURLReferenceCache.resetForTesting()

    let references = GitHubPullRequestURLReferenceCache.references(in: [
      "https://example.com/page",
      "https://github.com/owner/repo/pull/2",
      "https://github.com/owner/repo/tree/main",
      "https://github.com/owner/repo/pull/1"
    ])

    #expect(references.map(\.number) == [2, 1])
  }

  @Test("Stays bounded once capacity is reached")
  func staysBounded() {
    GitHubPullRequestURLReferenceCache.resetForTesting()

    let overflow = GitHubPullRequestURLReferenceCache.capacity + 10
    for index in 0..<overflow {
      _ = GitHubPullRequestURLReferenceCache.reference(
        for: "https://github.com/owner/repo/pull/\(index)"
      )
    }

    #expect(GitHubPullRequestURLReferenceCache.cachedEntryCount <= GitHubPullRequestURLReferenceCache.capacity)
    // Correct results survive the flush.
    let reference = GitHubPullRequestURLReferenceCache.reference(
      for: "https://github.com/owner/repo/pull/1"
    )
    #expect(reference?.number == 1)
  }
}
