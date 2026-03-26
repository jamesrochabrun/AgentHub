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
    dangerouslySkipPermissions: Bool = false,
    worktreeName: String? = nil,
    permissionModePlan: Bool = false,
    model: String? = nil,
    effortLevel: String? = nil,
    allowedTools: [String]? = nil,
    disallowedTools: [String]? = nil,
    codexApprovalPolicy: String? = nil
  ) -> [String] {
    let prefix = subcommandArgs

    switch mode {
    case .claude:
      var args: [String] = []

      let isNewSession = sessionId == nil || sessionId?.isEmpty == true || sessionId?.hasPrefix("pending-") == true

      // Add flags only for NEW sessions (not resume)
      if isNewSession {
        if permissionModePlan {
          // --permission-mode plan takes precedence; mutually exclusive with dangerously-skip-permissions
          args += ["--permission-mode", "plan"]
        } else if dangerouslySkipPermissions {
          args.append("--dangerously-skip-permissions")
        }
        if let name = worktreeName {
          if name.isEmpty {
            args.append("--worktree")
          } else {
            args += ["--worktree", name]
          }
        }

        // AI configuration flags
        if let model, !model.isEmpty {
          args += ["--model", model]
        }
        if let effortLevel, !effortLevel.isEmpty {
          args += ["--effort", effortLevel]
        }
        if let allowedTools, !allowedTools.isEmpty {
          args.append("--allowedTools")
          args.append(contentsOf: allowedTools)
        }
        if let disallowedTools, !disallowedTools.isEmpty {
          args.append("--disallowedTools")
          args.append(contentsOf: disallowedTools)
        }
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
      if let sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
        // Codex CLI resume: codex resume <SESSION_ID>
        return prefix + ["resume", sessionId]
      }

      // AI configuration flags for new Codex sessions
      var args: [String] = []
      if let model, !model.isEmpty {
        args += ["--model", model]
      }
      if let codexApprovalPolicy, !codexApprovalPolicy.isEmpty {
        args += ["-c", "approval_policy=\(codexApprovalPolicy)"]
      }
      if let effortLevel, !effortLevel.isEmpty {
        args += ["-c", "model_reasoning_effort=\(effortLevel)"]
      }

      // Start a new Codex session.
      // NOTE: Codex plan mode (ModeKind::Plan) is TUI-only and cannot be activated
      // via CLI flags. The UI layer disables the Codex pill when plan mode is on.
      if let prompt, !prompt.isEmpty {
        return prefix + args + [prompt]
      }
      return prefix + args
    }
  }
}

