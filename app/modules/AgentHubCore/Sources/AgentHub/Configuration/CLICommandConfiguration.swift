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

public struct XcodeBuildMCPBootstrap: Equatable, Sendable {
  /// Known-good XcodeBuildMCP release used by the npx fallback. Pinned so
  /// sessions don't pick up whatever npm's `latest` tag points at.
  public static let pinnedNPMVersion = "2.6.2"

  public var workingDirectory: String
  public var projectPath: String?
  public var workspacePath: String?
  public var simulatorUDID: String?
  public var enabledWorkflows: String

  public init(
    workingDirectory: String,
    projectPath: String? = nil,
    workspacePath: String? = nil,
    simulatorUDID: String? = nil,
    enabledWorkflows: String = "simulator,ui-automation"
  ) {
    self.workingDirectory = workingDirectory
    self.projectPath = projectPath
    self.workspacePath = workspacePath
    self.simulatorUDID = simulatorUDID
    self.enabledWorkflows = enabledWorkflows
  }

  var environment: [String: String] {
    var values = [
      "XCODEBUILDMCP_CWD": workingDirectory,
      "XCODEBUILDMCP_ENABLED_WORKFLOWS": enabledWorkflows,
      "XCODEBUILDMCP_PLATFORM": "iOS Simulator",
      "XCODEBUILDMCP_SENTRY_DISABLED": "true"
    ]
    if let workspacePath, !workspacePath.isEmpty {
      values["XCODEBUILDMCP_WORKSPACE_PATH"] = workspacePath
    } else if let projectPath, !projectPath.isEmpty {
      values["XCODEBUILDMCP_PROJECT_PATH"] = projectPath
    }
    if let simulatorUDID, !simulatorUDID.isEmpty {
      values["XCODEBUILDMCP_SIMULATOR_ID"] = simulatorUDID
    }
    return values
  }
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

  /// The executable name (first word of command). e.g. "agenthub" from "agenthub codex"
  public var executableName: String {
    commandParts.first ?? command
  }

  /// Subcommand arguments (remaining words after executable). e.g. ["codex"] from "agenthub codex"
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
    codexApprovalPolicy: String? = nil,
    xcodeBuildMCPBootstrap: XcodeBuildMCPBootstrap? = nil,
    appendSystemPrompt: String? = nil
  ) -> [String] {
    let prefix = normalizedPrefixArguments()

    switch mode {
    case .claude:
      var providerArgs: [String] = []

      let isNewSession = sessionId == nil || sessionId?.isEmpty == true || sessionId?.hasPrefix("pending-") == true

      if shouldConfigureMCP(agentHubCLIPath: agentHubMCPServerPath, xcodeBuildMCP: xcodeBuildMCPBootstrap) {
        providerArgs += [
          "--mcp-config",
          claudeMCPConfig(
            agentHubCLIPath: agentHubMCPServerPath,
            xcodeBuildMCP: xcodeBuildMCPBootstrap
          )
        ]
      }

      // Add flags only for NEW sessions (not resume)
      if isNewSession {
        if permissionModePlan {
          // --permission-mode plan takes precedence; mutually exclusive with dangerously-skip-permissions
          providerArgs += ["--permission-mode", "plan"]
        } else if dangerouslySkipPermissions {
          providerArgs.append("--dangerously-skip-permissions")
        }
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty {
          providerArgs += ["--append-system-prompt", appendSystemPrompt]
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
        if shouldConfigureMCP(agentHubCLIPath: agentHubMCPServerPath, xcodeBuildMCP: xcodeBuildMCPBootstrap) {
          providerArgs += codexMCPConfigArgs(
            agentHubCLIPath: agentHubMCPServerPath,
            xcodeBuildMCP: xcodeBuildMCPBootstrap
          )
        }
        return assembleArguments(prefix: prefix, providerArgs: providerArgs, trailingArgs: ["resume", sessionId])
      }

      // AI configuration flags for new Codex sessions
      var providerArgs: [String] = []
      if shouldConfigureMCP(agentHubCLIPath: agentHubMCPServerPath, xcodeBuildMCP: xcodeBuildMCPBootstrap) {
        providerArgs += codexMCPConfigArgs(
          agentHubCLIPath: agentHubMCPServerPath,
          xcodeBuildMCP: xcodeBuildMCPBootstrap
        )
      }
      if let appendSystemPrompt, !appendSystemPrompt.isEmpty {
        providerArgs += ["-c", "developer_instructions=\(tomlStringLiteral(appendSystemPrompt))"]
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
    guard isWrapperExecutable else { return prefix }

    if !prefix.contains("claude"), !prefix.contains("codex") {
      prefix.append(nativeProviderExecutableName)
    }
    return prefix
  }

  private func assembleArguments(prefix: [String], providerArgs: [String], trailingArgs: [String]) -> [String] {
    guard isWrapperExecutable else {
      return prefix + providerArgs + extraArgs + trailingArgs
    }

    let directProviderArgs = providerArgs + trailingArgs
    guard !directProviderArgs.isEmpty else {
      return prefix + extraArgs
    }

    return prefix + extraArgs + ["--"] + directProviderArgs
  }

  /// The provider's own CLI executable name (the binary invoked when no wrapper is used).
  private var nativeProviderExecutableName: String {
    switch mode {
    case .claude: return "claude"
    case .codex: return "codex"
    }
  }

  /// True when the configured command is a wrapper around the provider CLI rather than the
  /// provider CLI itself. Wrappers receive an injected provider subcommand and pass provider
  /// arguments after a `--` separator. Detected structurally (the executable isn't the native
  /// provider binary) so any wrapper works without hardcoding a specific tool name.
  private var isWrapperExecutable: Bool {
    URL(fileURLWithPath: executableName).lastPathComponent != nativeProviderExecutableName
  }

  private func shouldConfigureMCP(
    agentHubCLIPath: String?,
    xcodeBuildMCP: XcodeBuildMCPBootstrap?
  ) -> Bool {
    agentHubCLIPath?.isEmpty == false || xcodeBuildMCP != nil
  }

  private func claudeMCPConfig(
    agentHubCLIPath: String?,
    xcodeBuildMCP: XcodeBuildMCPBootstrap?
  ) -> String {
    var servers: [String: Any] = [:]
    if let agentHubCLIPath, !agentHubCLIPath.isEmpty {
      servers["agenthub"] = [
        "command": "/bin/sh",
        "args": ["-lc", mcpServerShellScript(agentHubCLIPath: agentHubCLIPath)]
      ]
    }
    if let xcodeBuildMCP {
      servers["XcodeBuildMCP"] = xcodeBuildMCPServerConfig(xcodeBuildMCP)
    }

    let config: [String: Any] = ["mcpServers": servers]
    guard let data = try? JSONSerialization.data(withJSONObject: config),
          let encoded = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return encoded
  }

  private func codexMCPConfigArgs(
    agentHubCLIPath: String?,
    xcodeBuildMCP: XcodeBuildMCPBootstrap?
  ) -> [String] {
    var args: [String] = []
    if let agentHubCLIPath, !agentHubCLIPath.isEmpty {
      args += [
        "-c", "mcp_servers.agenthub.command=\(tomlStringLiteral("/bin/sh"))",
        "-c", "mcp_servers.agenthub.args=\(tomlStringArray(["-lc", mcpServerShellScript(agentHubCLIPath: agentHubCLIPath)]))"
      ]
    }
    if let xcodeBuildMCP {
      args += [
        "-c", "mcp_servers.XcodeBuildMCP.command=\(tomlStringLiteral("/bin/zsh"))",
        "-c", "mcp_servers.XcodeBuildMCP.args=\(tomlStringArray(["-lc", xcodeBuildMCPShellScript()]))",
        "-c", "mcp_servers.XcodeBuildMCP.tool_timeout_sec=600"
      ]
      for (key, value) in xcodeBuildMCP.environment.sorted(by: { $0.key < $1.key }) {
        args += ["-c", "mcp_servers.XcodeBuildMCP.env.\(key)=\(tomlStringLiteral(value))"]
      }
    }
    return args
  }

  private func mcpServerShellScript(agentHubCLIPath: String) -> String {
    let escapedCLIPath = shellSingleQuoted(agentHubCLIPath)
    return """
    if [ -n "${AGENTHUB_CLI:-}" ] && [ -x "${AGENTHUB_CLI:-}" ]; then exec "$AGENTHUB_CLI" mcp-server; fi
    if [ -x \(escapedCLIPath) ]; then exec \(escapedCLIPath) mcp-server; fi
    exec agenthub mcp-server
    """
  }

  private func xcodeBuildMCPServerConfig(_ bootstrap: XcodeBuildMCPBootstrap) -> [String: Any] {
    [
      "command": "/bin/zsh",
      "args": ["-lc", xcodeBuildMCPShellScript()],
      "env": bootstrap.environment
    ]
  }

  private func xcodeBuildMCPShellScript() -> String {
    """
    PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}
    export PATH
    if command -v xcodebuildmcp >/dev/null 2>&1; then exec xcodebuildmcp mcp; fi
    export NVM_DIR="$HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then . "$NVM_DIR/nvm.sh"; fi
    if command -v nvm >/dev/null 2>&1; then nvm use --silent >/dev/null 2>&1 || true; fi
    exec npx -y xcodebuildmcp@\(XcodeBuildMCPBootstrap.pinnedNPMVersion) mcp
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
