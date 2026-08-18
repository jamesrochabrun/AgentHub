import Foundation
import Testing

@testable import AgentHubCore

@Suite("ClaudeArtifactURLDetector")
struct ClaudeArtifactURLDetectorTests {
  private let artifactID = "1502bf42-f488-49b5-a995-0402ef54bf6b"

  @Test("Strips the provenance query so one artifact has one canonical URL")
  func stripsProvenanceQuery() {
    let canonical = ClaudeArtifactURLDetector.canonicalURL(
      from: "https://claude.ai/code/artifact/\(artifactID)?via=auto_preview"
    )

    #expect(canonical?.absoluteString == "https://claude.ai/code/artifact/\(artifactID)")
  }

  @Test("Rejects claude.ai URLs that are not artifacts, and artifact paths on other hosts")
  func rejectsNonArtifactURLs() {
    #expect(ClaudeArtifactURLDetector.canonicalURL(from: "https://claude.ai/chat/\(artifactID)") == nil)
    #expect(ClaudeArtifactURLDetector.canonicalURL(from: "https://claude.ai/code/artifacts") == nil)
    #expect(ClaudeArtifactURLDetector.canonicalURL(from: "https://evil.example/code/artifact/\(artifactID)") == nil)
    #expect(ClaudeArtifactURLDetector.canonicalURL(from: "https://claude.ai.evil.example/code/artifact/\(artifactID)") == nil)
  }

  @Test("Trailing prose and markdown punctuation is not part of the id")
  func trimsTrailingPunctuation() {
    let text = """
      Published at https://claude.ai/code/artifact/\(artifactID). Also see \
      [the canvas](https://claude.ai/code/artifact/\(artifactID)).
      """

    let urls = ClaudeArtifactURLDetector.extractAll(from: text)

    #expect(urls.map(\.absoluteString) == ["https://claude.ai/code/artifact/\(artifactID)"])
  }

  @Test("Extracts every distinct artifact in first-seen order")
  func extractsDistinctArtifactsInOrder() {
    let second = "9c2b6c5e-1111-2222-3333-444455556666"
    let text = """
      First https://claude.ai/code/artifact/\(artifactID)
      Second https://claude.ai/code/artifact/\(second)?via=auto_preview
      Repeat https://claude.ai/code/artifact/\(artifactID)
      """

    let urls = ClaudeArtifactURLDetector.extractAll(from: text)

    #expect(urls.map(\.absoluteString) == [
      "https://claude.ai/code/artifact/\(artifactID)",
      "https://claude.ai/code/artifact/\(second)",
    ])
  }

  @Test("Recognizes the sign-in pages a signed-out artifact load lands on")
  func recognizesSignInPages() {
    #expect(ClaudeArtifactURLDetector.isSignInURL(URL(string: "https://claude.ai/login?returnTo=%2Fcode")!))
    #expect(ClaudeArtifactURLDetector.isSignInURL(URL(string: "https://claude.ai/oauth/authorize")!))
    #expect(ClaudeArtifactURLDetector.isSignInURL(URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!))
    #expect(!ClaudeArtifactURLDetector.isSignInURL(URL(string: "https://claude.ai/code/artifact/\(artifactID)")!))
    #expect(!ClaudeArtifactURLDetector.isSignInURL(URL(string: "https://evil.example/login")!))
  }

  @Test("Identifier round-trips from a canonical URL")
  func identifierRoundTrips() {
    let url = URL(string: "https://www.claude.ai/code/artifact/\(artifactID)?via=auto_preview")!

    #expect(ClaudeArtifactURLDetector.identifier(from: url) == artifactID)
    #expect(ClaudeArtifactURLDetector.identifier(from: URL(string: "https://claude.ai/code/artifact/short")!) == nil)
  }
}
