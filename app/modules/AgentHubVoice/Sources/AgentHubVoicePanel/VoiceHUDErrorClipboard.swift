import AppKit

enum VoiceHUDErrorClipboard {
  @MainActor
  static func copy(
    _ message: String,
    to pasteboard: NSPasteboard = .general
  ) {
    pasteboard.clearContents()
    pasteboard.setString(message, forType: .string)
  }
}
