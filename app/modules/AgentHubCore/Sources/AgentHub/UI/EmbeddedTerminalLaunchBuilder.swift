//
//  EmbeddedTerminalLaunchBuilder.swift
//  AgentHub
//

import AgentHubTerminalUI
import Foundation

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

  public static func shellLaunch(
    projectPath: String,
    shellPath: String? = nil
  ) -> EmbeddedTerminalLaunch {
    EmbeddedTerminalLaunch.shellLaunch(projectPath: projectPath, shellPath: shellPath)
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

}
