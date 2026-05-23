//
//  SessionRelationshipStoreProtocol.swift
//  AgentHub
//
//  Persistence API for directed session graph edges.
//

import Foundation

public protocol SessionRelationshipStoreProtocol: Sendable {
  func saveSessionRelationship(_ relationship: SessionRelationshipRecord) async throws
  func sessionRelationships(
    from sourceProvider: SessionProviderKind,
    sessionId: String,
    kind: SessionRelationshipKind?
  ) async throws -> [SessionRelationshipRecord]
  func sessionRelationships(
    to targetProvider: SessionProviderKind,
    sessionId: String,
    kind: SessionRelationshipKind?
  ) async throws -> [SessionRelationshipRecord]
  func deleteSessionRelationship(
    sourceProvider: SessionProviderKind,
    sourceSessionId: String,
    targetProvider: SessionProviderKind,
    targetSessionId: String,
    kind: SessionRelationshipKind
  ) async throws
}
