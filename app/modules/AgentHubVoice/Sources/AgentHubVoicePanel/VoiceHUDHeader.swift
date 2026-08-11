import SwiftUI

struct VoiceHUDHeader: View {
  let productName: String
  let onClose: () -> Void

  var body: some View {
    HStack {
      Label("\(productName) Voice", systemImage: "waveform.circle.fill")
        .font(.headline)

      Spacer()

      SettingsLink {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open Voice settings")

      Button("Close", systemImage: "xmark", action: onClose)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .accessibilityLabel("Close voice HUD")
    }
  }
}
