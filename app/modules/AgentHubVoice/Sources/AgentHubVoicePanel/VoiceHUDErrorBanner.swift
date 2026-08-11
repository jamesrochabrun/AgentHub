import AppKit
import SwiftUI

struct VoiceHUDErrorBanner: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      Text(message)
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)

      Button("Copy", systemImage: "doc.on.doc", action: copyMessage)
        .font(.caption)
        .help("Copy error details")

      if message.localizedCaseInsensitiveContains("microphone") {
        Button("Open Privacy Settings", action: openMicrophoneSettings)
          .font(.caption)
      }
    }
    .padding(9)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
  }

  private func copyMessage() {
    VoiceHUDErrorClipboard.copy(message)
  }

  private func openMicrophoneSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    ) else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
