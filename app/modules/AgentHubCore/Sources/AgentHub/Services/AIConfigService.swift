//
//  AIConfigService.swift
//  AgentHub
//
//  Protocol and actor service for reading/writing AI configuration settings.
//

import Foundation

/// Protocol for AI configuration persistence
public protocol AIConfigServiceProtocol: Sendable {
  /// Gets the AI config for a provider ("claude" or "codex")
  func getConfig(for provider: String) async throws -> AIConfigRecord?
  /// Saves or updates the AI config for a provider
  func saveConfig(_ record: AIConfigRecord) async throws
}

/// Actor-based service that delegates to SessionMetadataStore for AI config persistence.
public actor AIConfigService: AIConfigServiceProtocol {

  private let metadataStore: SessionMetadataStore

  public init(metadataStore: SessionMetadataStore) {
    self.metadataStore = metadataStore
  }

  public func getConfig(for provider: String) async throws -> AIConfigRecord? {
    try await metadataStore.getAIConfig(for: provider)
  }

  public func saveConfig(_ record: AIConfigRecord) async throws {
    try await metadataStore.saveAIConfig(record)
  }
}
