//
//  AgentWorkspaceSessionReference.swift
//  AgentHub
//
//  Provider-neutral identity used to reconcile workspace-owned sessions with
//  the normal monitored-session restoration flow.
//

import Foundation

public struct AgentWorkspaceSessionReference: Equatable, Hashable, Sendable {
  public let provider: SessionProviderKind
  public let sessionId: String
  public let projectPath: String

  public init(
    provider: SessionProviderKind,
    sessionId: String,
    projectPath: String
  ) {
    self.provider = provider
    self.sessionId = sessionId
    self.projectPath = projectPath
  }
}
