import Foundation
import Testing

@testable import AgentHubCore

@Suite("WebPreviewTextDraftPolicy")
struct WebPreviewTextDraftPolicyTests {

  @Test("A focused draft never yields to the page read-back")
  func focusedDraftWins() {
    #expect(
      WebPreviewTextDraftPolicy.shouldAdoptIncomingText(
        "Ship it",
        draft: "Ship it now",
        isEditing: true
      ) == false
    )
  }

  @Test("A trailing space typed by the user survives the trimmed read-back")
  func trailingWhitespaceIsNotReverted() {
    #expect(
      WebPreviewTextDraftPolicy.shouldAdoptIncomingText(
        "Ship it",
        draft: "Ship it ",
        isEditing: false
      ) == false
    )
  }

  @Test("An unfocused draft adopts text that really changed")
  func externalChangeIsAdopted() {
    #expect(
      WebPreviewTextDraftPolicy.shouldAdoptIncomingText(
        "Ship it today",
        draft: "Ship it ",
        isEditing: false
      )
    )
  }

  @Test("Collapsed whitespace compares equal")
  func normalizationCollapsesWhitespace() {
    #expect(WebPreviewTextDraftPolicy.normalized("  a \n b  ") == "a b")
    #expect(
      WebPreviewTextDraftPolicy.shouldAdoptIncomingText(
        "a b",
        draft: "a\n  b",
        isEditing: false
      ) == false
    )
  }
}
