//
//  TranscriptEntry.swift
//  AgentHub
//

import Foundation

public struct TranscriptEntry: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let timestamp: Date?
  public let role: TranscriptRole
  public let content: String
  public let provider: SessionProviderKind

  public init(
    id: UUID = UUID(),
    timestamp: Date?,
    role: TranscriptRole,
    content: String,
    provider: SessionProviderKind
  ) {
    self.id = id
    self.timestamp = timestamp
    self.role = role
    self.content = content
    self.provider = provider
  }
}

public enum TranscriptRole: String, Equatable, Sendable {
  case user
  case assistant
}
