import GhosttySwift
import Testing

@testable import Ghostty

struct AgentHubGhosttyClipboardConfirmationCopyTests {
  @Test
  func pasteCopyDescribesUnsafePaste() {
    let copy = AgentHubGhosttyClipboardConfirmationCopy.copy(for: .paste)

    #expect(copy.title == "Paste potentially unsafe text?")
    #expect(copy.allowButtonTitle == "Paste")
    #expect(copy.message.contains("terminal control sequences"))
  }

  @Test
  func osc52ReadCopyDescribesClipboardRead() {
    let copy = AgentHubGhosttyClipboardConfirmationCopy.copy(for: .osc52Read)

    #expect(copy.title == "Allow terminal to read the clipboard?")
    #expect(copy.allowButtonTitle == "Allow Read")
  }

  @Test
  func osc52WriteCopyDescribesClipboardWrite() {
    let copy = AgentHubGhosttyClipboardConfirmationCopy.copy(for: .osc52Write)

    #expect(copy.title == "Allow terminal to write the clipboard?")
    #expect(copy.allowButtonTitle == "Allow Write")
  }
}
