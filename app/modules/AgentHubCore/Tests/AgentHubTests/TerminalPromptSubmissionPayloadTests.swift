import Testing

@testable import AgentHubCore

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
}
