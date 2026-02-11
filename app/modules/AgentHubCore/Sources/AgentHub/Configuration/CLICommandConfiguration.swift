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

  /// The executable name (first word of command). e.g. "airchat" from "airchat codex"
  public var executableName: String {
    String(command.split(separator: " ", maxSplits: 1).first ?? Substring(command))
  }

  /// Subcommand arguments (remaining words after executable). e.g. ["codex"] from "airchat codex"
  public var subcommandArgs: [String] {
    let parts = command.split(separator: " ", maxSplits: 1)
    guard parts.count > 1 else { return [] }
    return [String(parts[1])]
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
    let prefix = subcommandArgs

    switch mode {
    case .claude:
      var args: [String] = []

      // Add flag only for NEW sessions (not resume)
      if dangerouslySkipPermissions && (sessionId == nil || sessionId?.isEmpty == true || sessionId?.hasPrefix("pending-") == true) {
        args.append("--dangerously-skip-permissions")
      }

      if let sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
        if let prompt, !prompt.isEmpty {
          return prefix + args + ["-r", sessionId, prompt]
        }
        return prefix + args + ["-r", sessionId]
      }
      if let prompt, !prompt.isEmpty {
        return prefix + args + [prompt]
      }
      return prefix + args

    case .codex:
      // Codex doesn't support this flag
      if let sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
        // Codex CLI resume: codex resume <SESSION_ID>
        return prefix + ["resume", sessionId]
      }
      // Start a new Codex session with optional prompt as positional argument
      if let prompt, !prompt.isEmpty {
        return prefix + [prompt]
      }
      return prefix
    }
  }
}

