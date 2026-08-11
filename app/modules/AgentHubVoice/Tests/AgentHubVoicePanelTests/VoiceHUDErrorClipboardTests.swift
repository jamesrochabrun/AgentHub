import AppKit
import Foundation
import Testing
@testable import AgentHubVoicePanel

@MainActor
struct VoiceHUDErrorClipboardTests {
  @Test
  func copiesTheCompleteErrorMessage() {
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("VoiceHUDErrorClipboardTests-\(UUID().uuidString)")
    )
    let message = #"invalid_api_key: The API key is invalid. {"request_id":"123"}"#

    VoiceHUDErrorClipboard.copy(message, to: pasteboard)

    #expect(pasteboard.string(forType: .string) == message)
  }
}
