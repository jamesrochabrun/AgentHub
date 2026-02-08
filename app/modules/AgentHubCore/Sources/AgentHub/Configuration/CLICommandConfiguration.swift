//
//  CLICommandConfiguration.swift
//  AgentHub
//
//  Provider-agnostic CLI command configuration for embedded terminals.
//

import Foundation

public enum CLICommandMode: String, Codable, Sendable {
  case claude
  case codex
}

public struct CLICommandConfiguration: Codable, Sendable {
  public var command: String
  public var additionalPaths: [String]
  public var mode: CLICommandMode

  public init(
    command: String,
    additionalPaths: [String] = [],
    mode: CLICommandMode
  ) {
    self.command = command
    self.additionalPaths = additionalPaths
    self.mode = mode
  }

  public static var claudeDefault: CLICommandConfiguration {
    CLICommandConfiguration(command: "claude", additionalPaths: [], mode: .claude)
  }

  public static var codexDefault: CLICommandConfiguration {
    CLICommandConfiguration(command: "codex", additionalPaths: [], mode: .codex)
  }

  public func argumentsForSession(
    sessionId: String?,
    prompt: String?,
    dangerouslySkipPermissions: Bool = false
  ) -> [String] {
    switch mode {
    case .claude:
      var args: [String] = []

      // Add flag only for NEW sessions (not resume)
      if dangerouslySkipPermissions && (sessionId == nil || sessionId?.isEmpty == true || sessionId?.hasPrefix("pending-") == true) {
        args.append("--dangerously-skip-permissions")
      }

      if let sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
        if let prompt, !prompt.isEmpty {
          return args + ["-r", sessionId, prompt]
        }
        return args + ["-r", sessionId]
      }
      if let prompt, !prompt.isEmpty {
        return args + [prompt]
      }
      return args

    case .codex:
      // Codex doesn't support this flag
      if let sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
        // Codex CLI resume: codex resume <SESSION_ID>
        return ["resume", sessionId]
      }
      // Start a new Codex session with optional prompt as positional argument
      if let prompt, !prompt.isEmpty {
        return [prompt]
      }
      return []
    }
  }
}

