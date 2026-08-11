import SwiftUI

/// The HUD panel's window chrome: Liquid Glass on macOS 26+, falling back to a
/// material card on earlier systems. Glass draws its own edge highlight, so the
/// manual hairline stroke only exists on the fallback path.
struct VoiceHUDChrome: ViewModifier {
  private static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content
        .glassEffect(.regular, in: Self.shape)
    } else {
      content
        .background(.regularMaterial)
        .clipShape(Self.shape)
        .overlay {
          Self.shape
            .stroke(.secondary.opacity(0.2))
        }
    }
  }
}

extension View {
  func voiceHUDChrome() -> some View {
    modifier(VoiceHUDChrome())
  }
}
