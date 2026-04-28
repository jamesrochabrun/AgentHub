//
//  EmbeddedTerminalLaunchBuilder.swift
//  AgentHub
//

import Foundation

struct EmbeddedTerminalLaunch {
  let shellCommand: String
  let environment: [String: String]

  var swiftTermExecutable: String { "/bin/bash" }
  var swiftTermArguments: [String] { ["-c", shellCommand] }
  var swiftTermEnvironment: [String] {
    var swiftTermEnvironment = environment
    swiftTermEnvironment["TERM_PROGRAM"] = "SwiftTerm"
    return swiftTermEnvironment.map { "\($0.key)=\($0.value)" }
  }

  var ghosttyCommand: String {
    "/bin/bash -c \(Self.shellEscapeSingleQuotedAllowingNewlines(shellCommand))"
  }

  private static func shellEscapeSingleQuotedAllowingNewlines(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
  }
}

enum EmbeddedTerminalLaunchError: LocalizedError, Equatable {
  case executableNotFound(String)

  var errorDescription: String? {
    switch self {
    case .executableNotFound(let command):
      return "Could not find '\(command)' command."
    }
  }
}

enum EmbeddedTerminalLaunchBuilder {
  static func cliLaunch(
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

    let environment = makeProcessEnvironment(additionalPaths: cliConfiguration.additionalPaths)
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

  static func shellLaunch(
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

  static func makeProcessEnvironment(additionalPaths: [String]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"
    environment.removeValue(forKey: "TERM_PROGRAM")

    let paths = CLIPathResolver.executableSearchPaths(additionalPaths: additionalPaths)
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
