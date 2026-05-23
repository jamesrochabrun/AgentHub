//
//  SessionRelationshipRecord.swift
//  AgentHub
//
//  Directed graph edges between CLI sessions.
//

import Foundation
import GRDB

public enum SessionRelationshipKind: String, Codable, CaseIterable, Sendable {
  case accessoryChild
}

public enum SessionRelationshipOrigin: String, Codable, CaseIterable, Sendable {
  case explicit
  case detected
}

public struct SessionRelationshipRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public var sourceProvider: String
  public var sourceSessionId: String
  public var targetProvider: String
  public var targetSessionId: String
  public var kind: String
  public var origin: String
  public var createdAt: Date
  public var updatedAt: Date

  public static var databaseTableName: String { "session_relationships" }

  public init(
    sourceProvider: SessionProviderKind,
    sourceSessionId: String,
    targetProvider: SessionProviderKind,
    targetSessionId: String,
    kind: SessionRelationshipKind,
    origin: SessionRelationshipOrigin,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.sourceProvider = sourceProvider.rawValue
    self.sourceSessionId = sourceSessionId
    self.targetProvider = targetProvider.rawValue
    self.targetSessionId = targetSessionId
    self.kind = kind.rawValue
    self.origin = origin.rawValue
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var sourceProviderKind: SessionProviderKind? {
    SessionProviderKind(rawValue: sourceProvider)
  }

  public var targetProviderKind: SessionProviderKind? {
    SessionProviderKind(rawValue: targetProvider)
  }

  public var relationshipKind: SessionRelationshipKind? {
    SessionRelationshipKind(rawValue: kind)
  }

  public var relationshipOrigin: SessionRelationshipOrigin? {
    SessionRelationshipOrigin(rawValue: origin)
  }
}
