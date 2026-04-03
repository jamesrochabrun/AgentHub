//
//  StorybookServiceProtocol.swift
//  Storybook
//
//  Protocol for managing Storybook dev server lifecycle.
//  AgentHubCore (or any consumer) provides the concrete implementation
//  by conforming DevServerManager or a wrapper to this protocol.
//

import Foundation

/// State of a Storybook server instance.
public enum StorybookServerState: Equatable, Sendable {
  case idle
  case starting
  case ready(url: URL)
  case failed(error: String)
}

/// Manages Storybook dev server lifecycle for a session.
///
/// Consumers implement this protocol to wire Storybook server management
/// into their existing dev server infrastructure.
///
/// ```swift
/// import Storybook
///
/// // In your app:
/// let service: StorybookService = MyStorybookService()
/// await service.start(for: sessionId, projectPath: path)
///
/// if case .ready(let url) = service.state(for: sessionId) {
///   // Navigate web preview to url
/// }
/// ```
@MainActor
public protocol StorybookService: Sendable {
  /// Starts a Storybook server for the given session at the specified project path.
  /// Idempotent — if already running, returns immediately.
  func start(for sessionId: String, projectPath: String) async

  /// Stops the Storybook server for the given session.
  func stop(for sessionId: String)

  /// Returns the current state of the Storybook server for a session.
  func state(for sessionId: String) -> StorybookServerState
}
