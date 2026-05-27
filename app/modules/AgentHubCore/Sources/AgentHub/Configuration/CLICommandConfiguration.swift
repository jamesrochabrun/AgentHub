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
    agentHubMCPServerPath: String? = nil,
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

      if let agentHubMCPServerPath, !agentHubMCPServerPath.isEmpty {
        args += ["--mcp-config", claudeMCPConfig(agentHubCLIPath: agentHubMCPServerPath)]
        args += ["--append-system-prompt", Self.agentHubMCPRoutingInstructions]
      }

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
        var args: [String] = []
        if let agentHubMCPServerPath, !agentHubMCPServerPath.isEmpty {
          args += codexMCPConfigArgs(agentHubCLIPath: agentHubMCPServerPath)
        }
        return prefix + args + ["resume", sessionId]
      }

      // AI configuration flags for new Codex sessions
      var args: [String] = []
      if let agentHubMCPServerPath, !agentHubMCPServerPath.isEmpty {
        args += codexMCPConfigArgs(agentHubCLIPath: agentHubMCPServerPath)
      }
      if let model, !model.isEmpty {
        args += ["--model", model]
      }
      if let codexApprovalPolicy {
        switch codexApprovalPolicy {
        case "full-auto":
          args += ["--sandbox", "workspace-write"]
        case "untrusted", "on-request", "never":
          args += ["-a", codexApprovalPolicy]
        default:
          break
        }
      }
      if let effortLevel, !effortLevel.isEmpty {
        args += ["-c", "model_reasoning_effort=\"\(effortLevel)\""]
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

  private func claudeMCPConfig(agentHubCLIPath: String) -> String {
    let config: [String: Any] = [
      "mcpServers": [
        "agenthub": [
          "command": "/bin/sh",
          "args": ["-lc", mcpServerShellScript(agentHubCLIPath: agentHubCLIPath)]
        ]
      ]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: config),
          let encoded = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return encoded
  }

  private func codexMCPConfigArgs(agentHubCLIPath: String) -> [String] {
    [
      "-c", "mcp_servers.agenthub.command=\(tomlStringLiteral("/bin/sh"))",
      "-c", "mcp_servers.agenthub.args=\(tomlStringArray(["-lc", mcpServerShellScript(agentHubCLIPath: agentHubCLIPath)]))",
      "-c", "developer_instructions=\(tomlStringLiteral(Self.agentHubMCPRoutingInstructions))"
    ]
  }

  private func mcpServerShellScript(agentHubCLIPath: String) -> String {
    let escapedCLIPath = shellSingleQuoted(agentHubCLIPath)
    return """
    if [ -n "${AGENTHUB_CLI:-}" ] && [ -x "${AGENTHUB_CLI:-}" ]; then exec "$AGENTHUB_CLI" mcp-server; fi
    if [ -x \(escapedCLIPath) ]; then exec \(escapedCLIPath) mcp-server; fi
    exec agenthub mcp-server
    """
  }

  private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func tomlStringLiteral(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let encoded = String(data: data, encoding: .utf8) else {
      return "\"\""
    }
    return encoded
  }

  private func tomlStringArray(_ values: [String]) -> String {
    "[\(values.map(tomlStringLiteral).joined(separator: ","))]"
  }

  private static let agentHubMCPRoutingInstructions = """
  In AgentHub sessions, when the user asks to create worktrees, launch agents/sessions, fan out work, split work across tasks, or start parallel/background work, immediately use the AgentHub MCP worktree-session tool. For one task use agenthub_create_worktree_session; for multiple tasks use agenthub_create_worktree_sessions. Infer concise branch names from the tasks. Pass only the actual task to perform as each launched session prompt; do not pass the user's worktree/session creation request itself. Do not use provider-native worktree/background-agent features for AgentHub-managed launches.
  """
}
