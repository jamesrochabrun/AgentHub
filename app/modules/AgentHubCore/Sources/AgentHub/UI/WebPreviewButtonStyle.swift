import SwiftUI

extension View {
  func webPreviewPrimaryButtonStyle() -> some View {
    buttonStyle(.borderedProminent)
      .tint(.brandPrimary)
  }

  func webPreviewSecondaryButtonStyle() -> some View {
    buttonStyle(.bordered)
      .tint(.brandPrimary)
  }
}
