//
//  WorkspaceSessionDetectionContext.swift
//  AgentHub
//

import Foundation

/// Runtime identity for an unlinked terminal tab that may start a CLI session.
///
/// The identifier is scoped to the mounted terminal surface. It intentionally
/// does not become part of the persisted workspace snapshot; persisted identity
/// comes from the linked Claude or Codex session once detection succeeds.
public struct WorkspaceSessionDetectionContext: Equatable, Sendable {
  public let id: String
  public let provider: SessionProviderKind?
  public let projectPath: String
  public let foregroundProcessID: Int32?

  public init(
    id: String,
    provider: SessionProviderKind?,
    projectPath: String,
    foregroundProcessID: Int32?
  ) {
    self.id = id
    self.provider = provider
    self.projectPath = projectPath
    self.foregroundProcessID = foregroundProcessID
  }
}
