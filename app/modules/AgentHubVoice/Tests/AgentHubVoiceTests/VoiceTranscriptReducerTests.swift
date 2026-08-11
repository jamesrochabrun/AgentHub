import Foundation
import Testing
@testable import AgentHubVoice

struct VoiceTranscriptReducerTests {
  @Test
  func partialEntriesAreCoalescedAndCompleted() {
    var reducer = VoiceTranscriptReducer()

    reducer.reduce(.userDelta("Hello"))
    reducer.reduce(.userDelta(" world"))
    reducer.reduce(.userCompleted("Hello world"))
    reducer.reduce(.assistantDelta("Hi"))
    reducer.reduce(.assistantCompleted("Hi there"))

    #expect(reducer.entries.count == 2)
    #expect(reducer.entries[0].role == .user)
    #expect(reducer.entries[0].text == "Hello world")
    #expect(!reducer.entries[0].isPartial)
    #expect(reducer.entries[1].role == .assistant)
    #expect(reducer.entries[1].text == "Hi there")
  }

  @Test
  func emptyCompletedTranscriptsAreIgnored() {
    var reducer = VoiceTranscriptReducer()

    reducer.reduce(.userCompleted(" \n "))
    reducer.reduce(.system("ready"))

    #expect(reducer.entries.map(\.text) == ["ready"])
  }
}
