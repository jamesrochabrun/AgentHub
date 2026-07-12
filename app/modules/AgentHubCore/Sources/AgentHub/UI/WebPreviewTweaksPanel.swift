import Canvas
import SwiftUI

struct WebPreviewTweaksPanel: View {
  let state: TweaksState
  @Binding var agentState: TweaksAgentState
  @Binding var defaultsSaveState: TweaksDefaultsSaveState
  let generationStartedAt: Date?
  let onSubmitDescription: (String) -> Void
  let onIdeas: () -> Void
  let onValueChange: (TweakProp, TweakPropValue) -> Void
  let onReset: () -> Void
  let onSaveDefaults: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      TweaksPanelView(
        state: state,
        agentState: TweakPanelStatusRouting.canvasAgentState(for: agentState),
        defaultsSaveState: TweakPanelStatusRouting.canvasDefaultsState(for: defaultsSaveState),
        onSubmitDescription: onSubmitDescription,
        onIdeas: onIdeas,
        onValueChange: onValueChange,
        onReset: onReset,
        onSaveDefaults: onSaveDefaults
      )
      .disabled(agentState == .working)

      if TweakPanelStatusRouting.showsHostStatus(
        agentState: agentState,
        defaultsState: defaultsSaveState
      ) {
        TweakPanelStatusArea(
          agentState: $agentState,
          defaultsSaveState: $defaultsSaveState,
          generationStartedAt: generationStartedAt
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
      }
    }
    .frame(width: 320)
  }
}
