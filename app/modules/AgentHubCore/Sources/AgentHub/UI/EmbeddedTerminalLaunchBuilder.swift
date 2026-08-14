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
    launchContext: String? = nil,
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
      launchContext: launchContext,
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      permissionModePlan: permissionModePlan,
      worktreeName: worktreeName,
      metadataStore: metadataStore,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: {
        AgentHubWorktreeSkillInstaller.installBundledSkillForAllProvidersBestEffort()
      },
      removeLegacyAgentHubSessionNamingSkill: {
        AgentHubSessionNamingSkillCleanup.removeInstalledSkillBestEffort()
      }
    )
  }

  static func cliLaunch(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?,
    launchContext: String? = nil,
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool,
    worktreeName: String?,
    metadataStore: SessionMetadataStore?,
    agentHubCLIPath: String? = nil,
    installAgentHubWorktreeSkill: () -> Void,
    removeLegacyAgentHubSessionNamingSkill: () -> Void = {},
    xcodeBuildMCPEnabled: Bool = XcodeBuildMCPPreflight.isEnabled(),
    xcodeBuildMCPToolingAvailable: () -> Bool = { XcodeBuildMCPPreflight.nodeToolingAvailable() },
    notifyXcodeBuildMCPToolingMissing: () -> Void = { Task { @MainActor in XcodeBuildMCPNodeNotice.notifyOnce() } }
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

    removeLegacyAgentHubSessionNamingSkill()

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
    let xcodeReference = XcodeProjectDetector.preferredProjectReference(at: workingDirectory)
    var xcodeBuildMCPBootstrap: XcodeBuildMCPBootstrap?
    if xcodeReference != nil, xcodeBuildMCPEnabled {
      if xcodeBuildMCPToolingAvailable() {
        xcodeBuildMCPBootstrap = makeXcodeBuildMCPBootstrap(
          workingDirectory: workingDirectory,
          reference: xcodeReference,
          metadataStore: metadataStore
        )
      } else {
        notifyXcodeBuildMCPToolingMissing()
      }
    }
    // Xcode projects get simulator-loop guidance at system-prompt level so
    // agents verify through the same live app surface the user is watching.
    // Tied to the bootstrap: guidance without the tools misleads agents.
    let simulatorGuidance = xcodeBuildMCPBootstrap == nil ? nil : SimulatorAgentGuidance.systemPrompt
    // Curated launch context rides the same out-of-band channel (Claude
    // `--append-system-prompt`, Codex `-c developer_instructions=`) instead of
    // the first user message. New sessions get it from the launch flow; resume
    // has no in-memory copy, so the text persisted at session resolution is
    // re-passed — it never entered conversation history.
    let resolvedLaunchContext: String?
    if isNewSession {
      resolvedLaunchContext = launchContext
    } else if let sessionId, !sessionId.isEmpty {
      resolvedLaunchContext = metadataStore?.getSessionLaunchContextTextSync(for: sessionId)
    } else {
      resolvedLaunchContext = nil
    }
    let appendSystemPrompt = combinedAppendSystemPrompt(
      simulatorGuidance: simulatorGuidance,
      launchContext: resolvedLaunchContext
    )
    let args = cliConfiguration.argumentsForSession(
      sessionId: sessionId,
      prompt: initialPrompt,
      agentHubMCPServerPath: resolvedAgentHubCLIPath,
      // Baked into the MCP server command rather than inherited: Codex and
      // Claude each decide for themselves what environment an MCP server is
      // spawned with, and a stripped AGENTHUB_PROVIDER makes every
      // session-scoped tool refuse to run.
      agentHubMCPEnvironment: agentHubSessionEnvironment(
        agentHubCLIPath: resolvedAgentHubCLIPath,
        providerKind: providerKind,
        projectPath: workingDirectory,
        sessionId: sessionId
      ),
      dangerouslySkipPermissions: dangerouslySkipPermissions,
      worktreeName: worktreeName,
      permissionModePlan: permissionModePlan,
      model: aiConfig?.defaultModel,
      effortLevel: aiConfig?.effortLevel,
      allowedTools: allowedTools.isEmpty ? nil : allowedTools,
      disallowedTools: disallowedTools.isEmpty ? nil : disallowedTools,
      codexApprovalPolicy: aiConfig?.approvalPolicy,
      xcodeBuildMCPBootstrap: xcodeBuildMCPBootstrap,
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
      let agentHubCLIDirectory = (agentHubCLIPath as NSString).deletingLastPathComponent
      paths.insert(agentHubCLIDirectory, at: 0)
    }

    environment.merge(
      agentHubSessionEnvironment(
        agentHubCLIPath: agentHubCLIPath,
        providerKind: providerKind,
        projectPath: projectPath,
        sessionId: sessionId
      )
    ) { _, new in new }

    let pathString = paths.joined(separator: ":")
    if let existingPath = environment["PATH"] {
      environment["PATH"] = "\(pathString):\(existingPath)"
    } else {
      environment["PATH"] = pathString
    }
    environment.merge(CLIEnvironmentOverrides.environment) { _, new in new }
    return environment
  }

  /// The `AGENTHUB_*` variables that tell the bundled `agenthub` CLI — and the
  /// MCP server it hosts — which AgentHub session it is running inside.
  ///
  /// Shared by the terminal process environment and the MCP server command so
  /// the two cannot drift: session-scoped tools (`agenthub_name_session`) fail
  /// outright when `AGENTHUB_PROVIDER` is missing.
  static func agentHubSessionEnvironment(
    agentHubCLIPath: String?,
    providerKind: SessionProviderKind?,
    projectPath: String?,
    sessionId: String?
  ) -> [String: String] {
    var environment: [String: String] = [:]
    if let agentHubCLIPath, !agentHubCLIPath.isEmpty {
      environment["AGENTHUB_CLI"] = agentHubCLIPath
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
    return environment
  }

  /// One line of provenance so the agent knows the block below is deliberate
  /// user input, not something that leaked into its system prompt.
  static let launchContextPreamble =
    "The user attached the following curated context when launching this session. Use it as background for their upcoming tasks."

  /// Single append-system-prompt value both providers receive. Guidance first
  /// (short operational instructions), then the bulky context block.
  static func combinedAppendSystemPrompt(
    simulatorGuidance: String?,
    launchContext: String?
  ) -> String? {
    var parts: [String] = []
    if let simulatorGuidance, !simulatorGuidance.isEmpty {
      parts.append(simulatorGuidance)
    }
    if let context = launchContext?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
      parts.append(launchContextPreamble + "\n" + context)
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
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

  private static func makeXcodeBuildMCPBootstrap(
    workingDirectory: String,
    reference: XcodeProjectReference?,
    metadataStore: SessionMetadataStore?
  ) -> XcodeBuildMCPBootstrap? {
    guard let reference else { return nil }
    let simulatorUDID = savedSimulatorUDID(
      forProjectPath: workingDirectory,
      metadataStore: metadataStore
    )
    switch reference.kind {
    case .project:
      return XcodeBuildMCPBootstrap(
        workingDirectory: workingDirectory,
        projectPath: reference.path,
        simulatorUDID: simulatorUDID
      )
    case .workspace:
      return XcodeBuildMCPBootstrap(
        workingDirectory: workingDirectory,
        workspacePath: reference.path,
        simulatorUDID: simulatorUDID
      )
    }
  }

  private static func savedSimulatorUDID(
    forProjectPath projectPath: String,
    metadataStore: SessionMetadataStore?
  ) -> String? {
    guard let metadataStore else { return nil }
    let normalizedProjectPath = normalizedPath(projectPath)
    let preferences = metadataStore.getProjectSimulatorPreferencesSync()
    return preferences
      .filter { $0.kind == .simulator && normalizedPath($0.projectPath) == normalizedProjectPath }
      .sorted { $0.updatedAt > $1.updatedAt }
      .first?
      .deviceIdentifier
  }

  private static func normalizedPath(_ path: String) -> String {
    let expanded = NSString(string: path).expandingTildeInPath
    return (expanded as NSString).standardizingPath
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
