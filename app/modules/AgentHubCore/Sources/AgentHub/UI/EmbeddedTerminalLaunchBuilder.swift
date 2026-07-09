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
    cliLaunch(
      sessionId: sessionId,
      projectPath: projectPath,
      cliConfiguration: cliConfiguration,
      initialPrompt: initialPrompt,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName,
      metadataStore: metadataStore,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: {
        AgentHubWorktreeSkillInstaller.installBundledSkillForAllProvidersBestEffort()
      }
    )
  }

  static func cliLaunch(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?,
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool,
    worktreeName: String?,
    metadataStore: SessionMetadataStore?,
    agentHubCLIPath: String? = nil,
    installAgentHubWorktreeSkill: () -> Void
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

    let isNewSession = sessionId == nil || sessionId?.isEmpty == true || sessionId?.hasPrefix("pending-") == true
    if isNewSession {
      installAgentHubWorktreeSkill()
    }

    let resolvedAgentHubCLIPath = agentHubCLIPath ?? AgentHubCLILocator.bundledCLIPath()
    let workingDirectory = projectPath.isEmpty ? NSHomeDirectory() : projectPath
    let providerKind = SessionProviderKind(cliMode: cliConfiguration.mode)
    let environment = makeProcessEnvironment(
      additionalPaths: cliConfiguration.additionalPaths,
      agentHubCLIPath: resolvedAgentHubCLIPath,
      providerKind: providerKind,
      projectPath: workingDirectory,
      sessionId: sessionId
    )
    let escapedPath = shellEscape(workingDirectory)
    let escapedCLIPath = shellEscape(executablePath)
    let aiConfig = metadataStore?.getAIConfigSync(for: cliConfiguration.mode.rawValue)
    let allowedTools = AIConfigRecord.parseToolPatterns(aiConfig?.allowedTools)
    let disallowedTools = AIConfigRecord.parseToolPatterns(aiConfig?.disallowedTools)
    // Xcode projects get simulator-loop guidance at system-prompt level:
    // tool descriptions alone don't stop agents from "validating" with a raw
    // `xcodebuild build` that never touches the app the user is watching.
    let appendSystemPrompt = XcodeProjectDetector.isXcodeProject(at: workingDirectory)
      ? SimulatorAgentGuidance.systemPrompt
      : nil
    let args = cliConfiguration.argumentsForSession(
      sessionId: sessionId,
      prompt: initialPrompt,
      agentHubMCPServerPath: resolvedAgentHubCLIPath,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      worktreeName: worktreeName,
      permissionModePlan: permissionModePlan,
      model: aiConfig?.defaultModel,
      effortLevel: aiConfig?.effortLevel,
      allowedTools: allowedTools.isEmpty ? nil : allowedTools,
      disallowedTools: disallowedTools.isEmpty ? nil : disallowedTools,
      codexApprovalPolicy: aiConfig?.approvalPolicy,
      appendSystemPrompt: appendSystemPrompt
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
    agentHubCLIPath: String? = AgentHubCLILocator.bundledCLIPath(),
    providerKind: SessionProviderKind? = nil,
    projectPath: String? = nil,
    sessionId: String? = nil
  ) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["LANG"] = "en_US.UTF-8"
    environment.removeValue(forKey: "TERM_PROGRAM")
    environment.removeValue(forKey: "AGENTHUB_CLI")
    environment.removeValue(forKey: "AGENTHUB_PROVIDER")
    environment.removeValue(forKey: "AGENTHUB_PROJECT_PATH")
    environment.removeValue(forKey: "AGENTHUB_SESSION_ID")

    var paths = CLIPathResolver.executableSearchPaths(additionalPaths: additionalPaths)
    if let agentHubCLIPath, !agentHubCLIPath.isEmpty {
      environment["AGENTHUB_CLI"] = agentHubCLIPath
      let agentHubCLIDirectory = (agentHubCLIPath as NSString).deletingLastPathComponent
      paths.insert(agentHubCLIDirectory, at: 0)
    }

    if let providerKind {
      environment["AGENTHUB_PROVIDER"] = providerKind.rawValue
    }
    if let projectPath, !projectPath.isEmpty {
      environment["AGENTHUB_PROJECT_PATH"] = projectPath
    }
    if let sessionId, !sessionId.isEmpty, !sessionId.hasPrefix("pending-") {
      environment["AGENTHUB_SESSION_ID"] = sessionId
    }

    let pathString = paths.joined(separator: ":")
    if let existingPath = environment["PATH"] {
      environment["PATH"] = "\(pathString):\(existingPath)"
    } else {
      environment["PATH"] = pathString
    }
    environment.merge(CLIEnvironmentOverrides.environment) { _, new in new }
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
