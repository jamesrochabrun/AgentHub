//
//  MonitoredSessionPresentation.swift
//  AgentHub
//

import Foundation

// MARK: - MonitoredSessionPresentation

public struct MonitoredSessionPresentation: Identifiable {
  public var id: String { session.id }

  public let session: CLISession
  public let stateModel: SessionMonitorStateModel

  public init(
    session: CLISession,
    stateModel: SessionMonitorStateModel
  ) {
    self.session = session
    self.stateModel = stateModel
  }
}
