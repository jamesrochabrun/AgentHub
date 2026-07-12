import Canvas
import SwiftUI

struct TweakPanelStatusArea: View {
  @Binding var agentState: TweaksAgentState
  @Binding var defaultsSaveState: TweaksDefaultsSaveState
  let generationStartedAt: Date?

  var body: some View {
    VStack(spacing: 8) {
      switch agentState {
      case .idle:
        EmptyView()
      case .working:
        TweakGenerationBanner(startedAt: generationStartedAt ?? .now)
      case .failed(let message):
        TweakStatusBanner(
          message: message,
          systemImage: "exclamationmark.circle",
          tint: .red,
          onDismiss: dismissAgentStatus
        )
      case .conflict:
        TweakStatusBanner(
          message: "The file changed while tweaks were being added. Submit again to use the latest version.",
          systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
          tint: .orange,
          onDismiss: dismissAgentStatus
        )
      }

      if case .failed(let message) = defaultsSaveState {
        TweakStatusBanner(
          message: message,
          systemImage: "exclamationmark.circle",
          tint: .red,
          onDismiss: dismissDefaultsStatus
        )
      }
    }
  }

  private func dismissAgentStatus() {
    agentState = .idle
  }

  private func dismissDefaultsStatus() {
    defaultsSaveState = .idle
  }
}
