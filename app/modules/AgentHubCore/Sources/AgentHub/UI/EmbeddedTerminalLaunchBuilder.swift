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
    metadataStore: SessionMetadataStore?
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

    let environment = makeProcessEnvironment(
      additionalPaths: cliConfiguration.additionalPaths,
      workspacePath: projectPath
    )
    let workingDirectory = projectPath.isEmpty ? NSHomeDirectory() : projectPath
    let escapedPath = shellEscape(workingDirectory)
    let escapedCLIPath = shellEscape(executablePath)

    let aiConfig = metadataStore?.getAIConfigSync(for: cliConfiguration.mode.rawValue)
    let allowedTools = AIConfigRecord.parseToolPatterns(aiConfig?.allowedTools)
    let disallowedTools = AIConfigRecord.parseToolPatterns(aiConfig?.disallowedTools)
    let args = cliConfiguration.argumentsForSession(
      sessionId: sessionId,
      prompt: initialPrompt,
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
    let environment = makeProcessEnvironment(additionalPaths: [], workspacePath: projectPath)
    let shellExecutable = resolveShellExecutablePath(shellPath)
    let escapedPath = shellEscape(projectPath.isEmpty ? NSHomeDirectory() : projectPath)
    let escapedShellPath = shellEscape(shellExecutable)
    let shellCommand = "cd '\(escapedPath)' && exec '\(escapedShellPath)' -l"
    return EmbeddedTerminalLaunch(shellCommand: shellCommand, environment: environment)
  }

  static func makeProcessEnvironment(
    additionalPaths: [String],
    workspacePath: String? = nil
  ) -> [String: String] {
    AgentHubProcessEnvironment.environment(
      additionalPaths: additionalPaths,
      workspacePath: workspacePath
    )
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
