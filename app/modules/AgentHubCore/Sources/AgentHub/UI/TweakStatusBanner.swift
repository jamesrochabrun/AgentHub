import SwiftUI

struct TweakStatusBanner: View {
  let message: String
  let systemImage: String
  let tint: Color
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: systemImage)
        .accessibilityHidden(true)

      Text(message)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 4)

      Button("Dismiss", systemImage: "xmark", action: onDismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .help("Dismiss")
    }
    .font(.caption)
    .foregroundStyle(tint)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
  }
}
