import Canvas

enum TweakPanelStatusRouting {
  static func canvasAgentState(for state: TweaksAgentState) -> TweaksAgentState {
    .idle
  }

  static func canvasDefaultsState(
    for state: TweaksDefaultsSaveState
  ) -> TweaksDefaultsSaveState {
    state == .saving ? .saving : .idle
  }

  static func showsHostStatus(
    agentState: TweaksAgentState,
    defaultsState: TweaksDefaultsSaveState
  ) -> Bool {
    if agentState != .idle {
      true
    } else if case .failed = defaultsState {
      true
    } else {
      false
    }
  }
}
