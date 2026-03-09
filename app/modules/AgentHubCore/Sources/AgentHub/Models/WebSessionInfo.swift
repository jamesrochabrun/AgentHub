//
//  WebSessionInfo.swift
//  AgentHub
//

import Foundation

/// Lightweight session representation serialized as JSON for the web client API.
public struct WebSessionInfo: Codable, Sendable {
  public let id: String
  public let slug: String
  public let projectPath: String
  public let branchName: String?
  public let statusLabel: String
  public let hasTerminal: Bool

  public init(session: CLISession, state: SessionMonitorState?, hasTerminal: Bool, customName: String? = nil) {
    self.id = session.id
    self.slug = customName ?? session.slug ?? String(session.id.prefix(8))
    self.projectPath = session.projectPath
    self.branchName = session.branchName
    self.statusLabel = state?.status.label ?? "idle"
    self.hasTerminal = hasTerminal
  }
}

private extension SessionStatus {
  var label: String {
    switch self {
    case .thinking: return "thinking"
    case .executingTool(let name): return "executing: \(name)"
    case .waitingForUser: return "waiting"
    case .awaitingApproval(let tool): return "approval: \(tool)"
    case .idle: return "idle"
    }
  }
}
