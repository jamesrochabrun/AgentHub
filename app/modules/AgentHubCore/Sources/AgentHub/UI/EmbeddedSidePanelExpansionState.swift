//
//  EmbeddedSidePanelExpansionState.swift
//  AgentHub
//

import SwiftUI

@MainActor
@Observable
final class EmbeddedSidePanelExpansionState<Payload: Equatable> {
  private(set) var expandedPayload: Payload?

  func isExpanded(for payload: Payload) -> Bool {
    expandedPayload == payload
  }

  func toggle(for payload: Payload) {
    if expandedPayload == payload {
      expandedPayload = nil
    } else {
      expandedPayload = payload
    }
  }

  func collapse(ifExpanded payload: Payload) {
    guard expandedPayload == payload else { return }
    expandedPayload = nil
  }

  func collapse() {
    expandedPayload = nil
  }

  func reconcile(currentPayload: Payload?) {
    guard let expandedPayload else { return }
    if currentPayload != expandedPayload {
      self.expandedPayload = nil
    }
  }
}
