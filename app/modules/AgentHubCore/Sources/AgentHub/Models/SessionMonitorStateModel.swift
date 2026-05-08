//
//  SessionMonitorStateModel.swift
//  AgentHub
//

import Foundation

// MARK: - SessionMonitorStateModel

/// Per-session observable state used to keep monitor updates scoped to the
/// views that render a single session.
@MainActor
@Observable
public final class SessionMonitorStateModel {
  public let sessionId: String
  public private(set) var state: SessionMonitorState?

  public init(sessionId: String, state: SessionMonitorState? = nil) {
    self.sessionId = sessionId
    self.state = state
  }

  public func update(_ state: SessionMonitorState?) {
    self.state = state
  }
}
