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
  /// Extra arguments configured by the user for each CLI invocation.
  public var extraArgs: [String]

  public init(
    command: String,
    additionalPaths: [String] = [],
    mode: CLICommandMode,
    extraArgs: [String] = []
  ) {
    self.command = command
    self.additionalPaths = additionalPaths
    self.mode = mode
    self.extraArgs = extraArgs
  }

  private enum CodingKeys: String, CodingKey {
    case command
    case additionalPaths
    case mode
    case extraArgs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    command = try container.decode(String.self, forKey: .command)
    additionalPaths = try container.decode([String].self, forKey: .additionalPaths)
    mode = try container.decode(CLICommandMode.self, forKey: .mode)
    extraArgs = try container.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
  }

  /// The executable name (first word of command). e.g. "airchat" from "airchat codex"
  public var executableName: String {
    commandParts.first ?? command
  }

  /// Subcommand arguments (remaining words after executable). e.g. ["codex"] from "airchat codex"
  public var subcommandArgs: [String] {
    Array(commandParts.dropFirst())
  }

  private var commandParts: [String] {
    Self.parseArgumentString(command)
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
    let prefix = normalizedPrefixArguments()

    switch mode {
    case .claude:
      var providerArgs: [String] = []

      let isNewSession = sessionId == nil || sessionId?.isEmpty == true || sessionId?.hasPrefix("pending-") == true

      if let agentHubMCPServerPath, !agentHubMCPServerPath.isEmpty {
        providerArgs += ["--mcp-config", claudeMCPConfig(agentHubCLIPath: agentHubMCPServerPath)]
      }

      // Add flags only for NEW sessions (not resume)
      if isNewSession {
        if permissionModePlan {
          // --permission-mode plan takes precedence; mutually exclusive with dangerously-skip-permissions
          providerArgs += ["--permission-mode", "plan"]
        } else if dangerouslySkipPermissions {
          providerArgs.append("--dangerously-skip-permissions")
        }
        if let name = worktreeName {
          if name.isEmpty {
            providerArgs.append("--worktree")
          } else {
            providerArgs += ["--worktree", name]
          }
        }

        // AI configuration flags
        if let model, !model.isEmpty {
          providerArgs += ["--model", model]
        }
        if let effortLevel, !effortLevel.isEmpty {
          providerArgs += ["--effort", effortLevel]
        }
        if let allowedTools, !allowedTools.isEmpty {
          providerArgs.append("--allowedTools")
          providerArgs.append(contentsOf: allowedTools)
        }
        if let disallowedTools, !disallowedTools.isEmpty {
          providerArgs.append("--disallowedTools")
          providerArgs.append(contentsOf: disallowedTools)
        }
      }

      if let sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
        var trailingArgs = ["-r", sessionId]
        if let prompt, !prompt.isEmpty {
          trailingArgs.append(prompt)
        }
        return assembleArguments(prefix: prefix, providerArgs: providerArgs, trailingArgs: trailingArgs)
      }
      var trailingArgs: [String] = []
      if let prompt, !prompt.isEmpty {
        trailingArgs.append(prompt)
      }
      return assembleArguments(prefix: prefix, providerArgs: providerArgs, trailingArgs: trailingArgs)

    case .codex:
      if let sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
        // Codex CLI resume: codex resume <SESSION_ID>
        var providerArgs: [String] = []
        if let agentHubMCPServerPath, !agentHubMCPServerPath.isEmpty {
          providerArgs += codexMCPConfigArgs(agentHubCLIPath: agentHubMCPServerPath)
        }
        return assembleArguments(prefix: prefix, providerArgs: providerArgs, trailingArgs: ["resume", sessionId])
      }

      // AI configuration flags for new Codex sessions
      var providerArgs: [String] = []
      if let agentHubMCPServerPath, !agentHubMCPServerPath.isEmpty {
        providerArgs += codexMCPConfigArgs(agentHubCLIPath: agentHubMCPServerPath)
      }
      if let model, !model.isEmpty {
        providerArgs += ["--model", model]
      }
      if let codexApprovalPolicy {
        switch codexApprovalPolicy {
        case "full-auto":
          providerArgs += ["--sandbox", "workspace-write"]
        case "untrusted", "on-request", "never":
          providerArgs += ["-a", codexApprovalPolicy]
        default:
          break
        }
      }
      if let effortLevel, !effortLevel.isEmpty {
        providerArgs += ["-c", "model_reasoning_effort=\"\(effortLevel)\""]
      }

      // Start a new Codex session.
      // NOTE: Codex plan mode (ModeKind::Plan) is TUI-only and cannot be activated
      // via CLI flags. The UI layer disables the Codex pill when plan mode is on.
      var trailingArgs: [String] = []
      if let prompt, !prompt.isEmpty {
        trailingArgs.append(prompt)
      }
      return assembleArguments(prefix: prefix, providerArgs: providerArgs, trailingArgs: trailingArgs)
    }
  }

  public static func parseArgumentString(_ value: String) -> [String] {
    var arguments: [String] = []
    var current = ""
    var quote: Character?
    var escaping = false
    var hasCurrentArgument = false

    for character in value {
      if escaping {
        current.append(character)
        hasCurrentArgument = true
        escaping = false
        continue
      }

      if character == "\\" {
        escaping = true
        hasCurrentArgument = true
        continue
      }

      if let activeQuote = quote {
        if character == activeQuote {
          quote = nil
        } else {
          current.append(character)
          hasCurrentArgument = true
        }
        continue
      }

      if character == "'" || character == "\"" {
        quote = character
        hasCurrentArgument = true
        continue
      }

      if character.isWhitespace {
        if hasCurrentArgument {
          arguments.append(current)
          current = ""
          hasCurrentArgument = false
        }
        continue
      }

      current.append(character)
      hasCurrentArgument = true
    }

    if escaping {
      current.append("\\")
    }
    if hasCurrentArgument {
      arguments.append(current)
    }
    return arguments
  }

  private func normalizedPrefixArguments() -> [String] {
    var prefix = subcommandArgs
    guard isAirChatExecutable else { return prefix }

    let providerSubcommand: String
    switch mode {
    case .claude:
      providerSubcommand = "claude"
    case .codex:
      providerSubcommand = "codex"
    }

    if !prefix.contains("claude"), !prefix.contains("codex") {
      prefix.append(providerSubcommand)
    }
    return prefix
  }

  private func assembleArguments(prefix: [String], providerArgs: [String], trailingArgs: [String]) -> [String] {
    guard isAirChatExecutable else {
      return prefix + providerArgs + extraArgs + trailingArgs
    }

    let directProviderArgs = providerArgs + trailingArgs
    guard !directProviderArgs.isEmpty else {
      return prefix + extraArgs
    }

    return prefix + extraArgs + ["--"] + directProviderArgs
  }

  private var isAirChatExecutable: Bool {
    URL(fileURLWithPath: executableName).lastPathComponent == "airchat"
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
      "-c", "mcp_servers.agenthub.args=\(tomlStringArray(["-lc", mcpServerShellScript(agentHubCLIPath: agentHubCLIPath)]))"
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
}
