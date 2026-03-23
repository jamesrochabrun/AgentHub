import Foundation
import Testing

@testable import AgentHubCore

@Suite("LocalhostURLNormalizer")
struct LocalhostURLNormalizerTests {

  @Test("Extracts sanitized localhost URL from server output")
  func extractsSanitizedURLFromServerOutput() {
    let text = "Server is running at http://localhost:3000/**. Ready in 1200ms."

    let url = LocalhostURLNormalizer.extractFirstURL(from: text)

    #expect(url?.absoluteString == "http://localhost:3000")
  }

  @Test("Strips decorative wildcard suffix but keeps meaningful route")
  func stripsDecorativeWildcardSuffixButKeepsRoute() {
    let url = LocalhostURLNormalizer.sanitize("http://localhost:3000/dashboard/**")

    #expect(url?.absoluteString == "http://localhost:3000/dashboard")
  }
}
