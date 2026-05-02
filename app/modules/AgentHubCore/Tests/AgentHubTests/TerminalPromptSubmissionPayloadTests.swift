import Testing

@testable import AgentHubCore
@testable import AgentHubTerminalUI

@Suite("TerminalPromptSubmissionPayload")
struct TerminalPromptSubmissionPayloadTests {

  @Test("Non-bracketed payload appends one carriage return")
  func nonBracketedPayloadAppendsCarriageReturn() {
    let prompt = "Queued update\nwith multiple lines"

    let payload = TerminalPromptSubmissionPayload.bytes(
      prompt: prompt,
      bracketedPasteMode: false
    )
    let expected = Array(prompt.utf8) + [0x0D]

    #expect(payload == expected)
  }

  @Test("Bracketed payload wraps prompt before final carriage return")
  func bracketedPayloadWrapsPromptBeforeSubmitting() {
    let prompt = "Queued update\nwith multiple lines"
    let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    let payload = TerminalPromptSubmissionPayload.bytes(
      prompt: prompt,
      bracketedPasteMode: true
    )
    let expected = start + Array(prompt.utf8) + end + [0x0D]

    #expect(payload == expected)
  }

  @Test("Large multiline payload preserves byte order")
  func largeMultilinePayloadPreservesByteOrder() {
    let prompt = (0..<500)
      .map { "Update \($0): tighten spacing around the selected region." }
      .joined(separator: "\n")

    let payload = TerminalPromptSubmissionPayload.bytes(
      prompt: prompt,
      bracketedPasteMode: false
    )
    let expected = Array(prompt.utf8)

    #expect(payload.dropLast() == ArraySlice(expected))
    #expect(payload.last == 0x0D)
  }

  @Test("textBytes without bracketed paste returns raw prompt bytes")
  func textBytesNonBracketed() {
    let prompt = "hello world"

    let payload = TerminalPromptSubmissionPayload.textBytes(
      prompt: prompt,
      bracketedPasteMode: false
    )

    #expect(payload == Array(prompt.utf8))
  }

  @Test("textBytes with bracketed paste wraps but omits carriage return")
  func textBytesBracketed() {
    let prompt = "hello world"
    let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    let payload = TerminalPromptSubmissionPayload.textBytes(
      prompt: prompt,
      bracketedPasteMode: true
    )
    let expected = start + Array(prompt.utf8) + end

    #expect(payload == expected)
    #expect(!payload.contains(0x0D))
  }

  @Test("bracketedPasteTextBytes always wraps and omits carriage return")
  func bracketedPasteTextBytesAlwaysWraps() {
    let prompt = "Queued update\nwith multiple lines"
    let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    let end: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    let payload = TerminalPromptSubmissionPayload.bracketedPasteTextBytes(prompt: prompt)

    #expect(payload == start + Array(prompt.utf8) + end)
    #expect(!payload.contains(0x0D))
  }
}
