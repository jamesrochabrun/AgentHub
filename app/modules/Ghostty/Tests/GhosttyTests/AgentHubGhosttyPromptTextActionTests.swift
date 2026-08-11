import Testing
@testable import Ghostty

struct AgentHubGhosttyPromptTextActionTests {
  @Test
  func wrapsPromptInBracketedPasteMarkers() {
    #expect(
      AgentHubGhosttyPromptTextAction.bracketedPaste("Hello") ==
        "text:\\x1b[200~Hello\\x1b[201~"
    )
  }

  @Test
  func escapesBackslashesSoZigLiteralDecodingCannotMangleThePrompt() {
    #expect(
      AgentHubGhosttyPromptTextAction.escaped(#"path\to\file and \x1b"#) ==
        #"path\\to\\file and \\x1b"#
    )
  }

  @Test
  func escapesDoubleQuotesThatWouldTerminateTheLiteral() {
    #expect(
      AgentHubGhosttyPromptTextAction.escaped(#"say "hi""#) ==
        #"say \"hi\""#
    )
  }

  @Test
  func escapesControlCharactersIncludingNewlines() {
    #expect(
      AgentHubGhosttyPromptTextAction.escaped("line one\nline two\ttabbed\u{1B}") ==
        #"line one\x0aline two\x09tabbed\x1b"#
    )
  }

  @Test
  func passesUnicodeThroughUnchanged() {
    #expect(
      AgentHubGhosttyPromptTextAction.escaped("café 🚀 日本語") == "café 🚀 日本語"
    )
  }
}
