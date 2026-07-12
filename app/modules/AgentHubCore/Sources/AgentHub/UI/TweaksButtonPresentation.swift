//
//  TweaksButtonPresentation.swift
//  AgentHub
//

import Canvas

struct TweaksButtonPresentation: Equatable {
  let isLoading: Bool
  let accessibilityLabel: String

  static func resolve(agentState: TweaksAgentState) -> TweaksButtonPresentation {
    let isLoading = agentState == .working
    return TweaksButtonPresentation(
      isLoading: isLoading,
      accessibilityLabel: isLoading ? "Creating tweaks" : "Tweaks"
    )
  }
}
