//
//  TerminalWorkspaceStoreProtocol.swift
//  AgentHub
//
//  Persistence abstraction for embedded terminal workspace layouts.
//

import Foundation

public protocol TerminalWorkspaceStoreProtocol: Sendable {
  func loadTerminalWorkspace(
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) -> TerminalWorkspaceSnapshot?

  func saveTerminalWorkspace(
    _ snapshot: TerminalWorkspaceSnapshot,
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) async throws

  func deleteTerminalWorkspace(
    provider: SessionProviderKind,
    sessionId: String,
    backend: EmbeddedTerminalBackend
  ) async throws
}
