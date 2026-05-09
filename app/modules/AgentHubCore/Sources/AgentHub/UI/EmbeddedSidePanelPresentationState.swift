//
//  EmbeddedSidePanelPresentationState.swift
//  AgentHub
//

import SwiftUI

@MainActor
@Observable
final class EmbeddedSidePanelPresentationState<Payload: Equatable> {
  private enum DeferredTransition {
    case mount(id: UInt64, payload: Payload)
    case removeShell(id: UInt64)

    var id: UInt64 {
      switch self {
      case .mount(let id, _), .removeShell(let id):
        return id
      }
    }
  }

  private(set) var shellPayload: Payload?
  private(set) var mountedPayload: Payload?

  private var transitionID: UInt64 = 0
  private var deferredTransition: DeferredTransition?

  var currentPayload: Payload? {
    mountedPayload ?? shellPayload
  }

  @discardableResult
  func open(_ payload: Payload) -> UInt64 {
    transitionID += 1
    let id = transitionID

    withAnimationsDisabled {
      shellPayload = payload
      mountedPayload = nil
    }
    deferredTransition = .mount(id: id, payload: payload)

    return id
  }

  @discardableResult
  func close() -> UInt64 {
    transitionID += 1
    let id = transitionID

    mountedPayload = nil
    deferredTransition = .removeShell(id: id)

    return id
  }

  func completeDeferredTransition(id: UInt64) {
    guard let deferredTransition, deferredTransition.id == id else { return }

    switch deferredTransition {
    case .mount(_, let payload):
      guard shellPayload == payload else { return }
      mountedPayload = payload

    case .removeShell:
      guard mountedPayload == nil else { return }
      withAnimationsDisabled {
        shellPayload = nil
      }
    }

    self.deferredTransition = nil
  }

  private func withAnimationsDisabled(_ updates: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, updates)
  }
}
