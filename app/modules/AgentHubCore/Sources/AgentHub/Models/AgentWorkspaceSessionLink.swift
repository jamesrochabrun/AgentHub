//
//  AgentWorkspaceSessionLink.swift
//  AgentHub
//
//  Persisted ownership link between a neutral workspace and a CLI session.
//

import Foundation
import GRDB

public struct AgentWorkspaceSessionLink: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public var workspaceId: String
  public var provider: String
  public var sessionId: String
  public var origin: String
  public var createdAt: Date
  public var updatedAt: Date

  public static var databaseTableName: String { "workspace_session_links" }

  public init(
    workspaceId: String,
    provider: SessionProviderKind,
    sessionId: String,
    origin: SessionRelationshipOrigin,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.workspaceId = workspaceId
    self.provider = provider.rawValue
    self.sessionId = sessionId
    self.origin = origin.rawValue
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var providerKind: SessionProviderKind? {
    SessionProviderKind(rawValue: provider)
  }

  public var relationshipOrigin: SessionRelationshipOrigin? {
    SessionRelationshipOrigin(rawValue: origin)
  }
}
