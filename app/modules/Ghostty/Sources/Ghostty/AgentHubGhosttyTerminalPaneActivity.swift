//
//  AgentHubGhosttyTerminalPaneActivity.swift
//  AgentHub
//

import GhosttySwift

enum AgentHubGhosttyTerminalPaneActivity: Equatable {
  case starting
  case closingPanel
  case closingTerminal

  var message: String {
    switch self {
    case .starting:
      return "Starting terminal..."
    case .closingPanel:
      return "Closing panel..."
    case .closingTerminal:
      return "Closing terminal..."
    }
  }
}

final class AgentHubGhosttyPaneActivityRegistry {
  private var activities: [TerminalPanelID: AgentHubGhosttyTerminalPaneActivity] = [:]

  func markStarting(_ panelID: TerminalPanelID) {
    activities[panelID] = .starting
  }

  func markClosingPanel(_ panelID: TerminalPanelID) {
    activities[panelID] = .closingPanel
  }

  func markClosingTerminal(_ panelID: TerminalPanelID) {
    activities[panelID] = .closingTerminal
  }

  @discardableResult
  func clear(_ panelID: TerminalPanelID) -> Bool {
    activities.removeValue(forKey: panelID) != nil
  }

  func reset() {
    activities.removeAll()
  }

  func activity(for panelID: TerminalPanelID) -> AgentHubGhosttyTerminalPaneActivity? {
    activities[panelID]
  }
}
