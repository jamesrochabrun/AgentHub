//
//  EmbeddedTerminalLaunchBuilder.swift
//  AgentHub
//

import Foundation

public struct EmbeddedTerminalLaunch {
  public let shellCommand: String
  public let environment: [String: String]

  public init(shellCommand: String, environment: [String: String]) {
    self.shellCommand = shellCommand
    self.environment = environment
  }

  public var swiftTermExecutable: String { "/bin/bash" }
  public var swiftTermArguments: [String] { ["-c", shellCommand] }
  public var swiftTermEnvironment: [String] {
    var swiftTermEnvironment = environment
    swiftTermEnvironment["TERM_PROGRAM"] = "SwiftTerm"
    return swiftTermEnvironment.map { "\($0.key)=\($0.value)" }
  }

  public var ghosttyCommand: String {
    "/bin/bash -c \(Self.shellEscapeSingleQuotedAllowingNewlines(shellCommand))"
  }

  private static func shellEscapeSingleQuotedAllowingNewlines(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
  }
}

public enum EmbeddedTerminalLaunchError: LocalizedError, Equatable {
  case executableNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let command):
      return "Could not find '\(command)' command."
    }
  }
}

public enum EmbeddedTerminalLaunchBuilder {
  public static func cliLaunch(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?,
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool,
    worktreeName: String?,
    metadataStore: SessionMetadataStore?,
    agentHubCLIPath: String? = nil
  ) -> Result<EmbeddedTerminalLaunch, EmbeddedTerminalLaunchError> {
    let executablePath: String?
    switch cliConfiguration.mode {
    case .codex:
      executablePath = TerminalLauncher.findCodexExecutable(
        command: cliConfiguration.executableName,
        additionalPaths: cliConfiguration.additionalPaths
      )
    case .claude:
      executablePath = TerminalLauncher.findExecutable(
        command: cliConfiguration.executableName,
        additionalPaths: cliConfiguration.additionalPaths
      )
    }

    guard let executablePath else {
      return .failure(.executableNotFound(cliConfiguration.command))
    }

    let resolvedAgentHubCLIPath = agentHubCLIPath ?? AgentHubCLILocator.bundledCLIPath()
    let environment = makeProcessEnvironment(
      additionalPaths: cliConfiguration.additionalPaths,
      agentHubCLIPath: resolvedAgentHubCLIPath
    )
    let workingDirectory = projectPath.isEmpty ? NSHomeDirectory() : projectPath
    let escapedPath = shellEscape(workingDirectory)
    let escapedCLIPath = shellEscape(executablePath)
    let launchPrompt = AgentHubSessionInstructionBuilder.decoratedPrompt(
      initialPrompt,
      sessionId: sessionId,
      agentHubCLIPath: resolvedAgentHubCLIPath
    )

    let aiConfig = metadataStore?.getAIConfigSync(for: cliConfiguration.mode.rawValue)
    let allowedTools = AIConfigRecord.parseToolPatterns(aiConfig?.allowedTools)
    let disallowedTools = AIConfigRecord.parseToolPatterns(aiConfig?.disallowedTools)
    let args = cliConfiguration.argumentsForSession(
      sessionId: sessionId,
      prompt: launchPrompt,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      worktreeName: worktreeName,
      permissionModePlan: permissionModePlan,
      model: aiConfig?.defaultModel,
      effortLevel: aiConfig?.effortLevel,
      allowedTools: allowedTools.isEmpty ? nil : allowedTools,
      disallowedTools: disallowedTools.isEmpty ? nil : disallowedTools,
      codexApprovalPolicy: aiConfig?.approvalPolicy
    )
    let joinedArgs = args
      .map { "'\(shellEscape($0))'" }
      .joined(separator: " ")
    let shellCommand = joinedArgs.isEmpty
      ? "cd '\(escapedPath)' && exec '\(escapedCLIPath)'"
      : "cd '\(escapedPath)' && exec '\(escapedCLIPath)' \(joinedArgs)"

    return .success(EmbeddedTerminalLaunch(shellCommand: shellCommand, environment: environment))
  }

  public static func shellLaunch(
    projectPath: String,
    shellPath: String? = nil
  ) -> EmbeddedTerminalLaunch {
    let environment = makeProcessEnvironment(additionalPaths: [])
    let shellExecutable = resolveShellExecutablePath(shellPath)
    let escapedPath = shellEscape(projectPath.isEmpty ? NSHomeDirectory() : projectPath)
    let escapedShellPath = shellEscape(shellExecutable)
    let shellCommand = "cd '\(escapedPath)' && exec '\(escapedShellPath)' -l"
    return EmbeddedTerminalLaunch(shellCommand: shellCommand, environment: environment)
  }

  static func makeProcessEnvironment(
    additionalPaths: [String],
    agentHubCLIPath: String? = AgentHubCLILocator.bundledCLIPath()
  ) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"
    environment.removeValue(forKey: "TERM_PROGRAM")

    var paths = CLIPathResolver.executableSearchPaths(additionalPaths: additionalPaths)
    if let agentHubCLIPath, !agentHubCLIPath.isEmpty {
      environment["AGENTHUB_CLI"] = agentHubCLIPath
      let agentHubCLIDirectory = (agentHubCLIPath as NSString).deletingLastPathComponent
      paths.insert(agentHubCLIDirectory, at: 0)
    }

    let pathString = paths.joined(separator: ":")
    if let existingPath = environment["PATH"] {
      environment["PATH"] = "\(pathString):\(existingPath)"
    } else {
      environment["PATH"] = pathString
    }
    return environment
  }

  static func shellEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
  }

  private static func resolveShellExecutablePath(_ shellPath: String?) -> String {
    let candidate = shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    if FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    return "/bin/zsh"
  }
}

enum AgentHubCLILocator {
  static func bundledCLIPath(
    bundle: Bundle = .main,
    fileManager: FileManager = .default
  ) -> String? {
    guard let bundleURL = bundle.bundleURL as URL? else {
      return nil
    }

    let cliPath = bundleURL
      .appendingPathComponent("Contents")
      .appendingPathComponent("Helpers")
      .appendingPathComponent("agenthub")
      .path
    guard fileManager.isExecutableFile(atPath: cliPath) else {
      return nil
    }
    return cliPath
  }
}

enum AgentHubSessionInstructionBuilder {
  private static let marker = "AgentHub session context:"

  static func decoratedPrompt(
    _ prompt: String?,
    sessionId: String?,
    agentHubCLIPath: String?
  ) -> String? {
    guard isNewSession(sessionId),
          agentHubCLIPath != nil,
          let prompt,
          !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !prompt.hasPrefix(marker) else {
      return prompt
    }

    return """
    \(marker)
    - The AgentHub CLI is available as `agenthub` and at `$AGENTHUB_CLI`.
    - For AgentHub-managed worktree operations, use `agenthub worktree ... --json` instead of direct `git worktree` commands.

    User request:
    \(prompt)
    """
  }

  private static func isNewSession(_ sessionId: String?) -> Bool {
    sessionId == nil || sessionId?.isEmpty == true || sessionId?.hasPrefix("pending-") == true
  }
}
