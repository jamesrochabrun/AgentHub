import Foundation
import Testing

@testable import AgentHubCore

@Suite("EmbeddedTerminalLaunchBuilder AgentHub CLI context", .serialized)
struct EmbeddedTerminalLaunchBuilderAgentHubCLITests {
  private let agentHubCLIPath = "/Applications/AgentHub.app/Contents/Helpers/agenthub"

  @Test("CLI environment variables are empty by default")
  func cliEnvironmentVariablesAreEmptyByDefault() {
    let suite = EphemeralDefaultsSuite(prefix: "AgentHubTests.CLIEnvironment")
    defer { suite.cleanUp() }
    let defaults = suite.defaults

    #expect(CLIEnvironmentOverrides.variables(defaults: defaults).isEmpty)
    #expect(CLIEnvironmentOverrides.environment(from: CLIEnvironmentOverrides.variables(defaults: defaults)).isEmpty)
  }

  @Test("Invalid CLI environment variable names are filtered")
  func invalidCLIEnvironmentVariableNamesAreFiltered() {
    let environment = CLIEnvironmentOverrides.environment(from: [
      CLIEnvironmentVariable(name: "VALID", value: "first"),
      CLIEnvironmentVariable(name: "", value: "empty"),
      CLIEnvironmentVariable(name: "HAS=EQUALS", value: "equals"),
      CLIEnvironmentVariable(name: "HAS\nNEWLINE", value: "newline"),
      CLIEnvironmentVariable(name: "HAS\0NUL", value: "nul"),
      CLIEnvironmentVariable(name: " VALID ", value: "last")
    ])

    #expect(environment == ["VALID": "last"])
  }

  @Test("CLI environment variable values persist through UserDefaults")
  func cliEnvironmentVariablesPersistThroughUserDefaults() {
    let suite = EphemeralDefaultsSuite(prefix: "AgentHubTests.CLIEnvironment")
    defer { suite.cleanUp() }
    let defaults = suite.defaults

    let variables = [
      CLIEnvironmentVariable(id: UUID(), name: "ONE", value: "1"),
      CLIEnvironmentVariable(id: UUID(), name: "TWO", value: "value with spaces")
    ]

    CLIEnvironmentOverrides.save(variables, defaults: defaults)

    #expect(CLIEnvironmentOverrides.variables(defaults: defaults) == variables)
  }

  @Test("Embedded terminal environment merges configured CLI variables")
  func embeddedTerminalEnvironmentMergesConfiguredCLIVariables() {
    withStandardCLIEnvironmentVariables([
      CLIEnvironmentVariable(name: "AGENTHUB_TEST_ENV_OVERRIDE", value: "embedded")
    ]) {
      let environment = EmbeddedTerminalLaunchBuilder.makeProcessEnvironment(
        additionalPaths: [],
        agentHubCLIPath: agentHubCLIPath
      )

      #expect(environment["AGENTHUB_TEST_ENV_OVERRIDE"] == "embedded")
    }
  }

  @Test("Terminal launcher exports CLI variables with deterministic shell escaping")
  func terminalLauncherExportsCLIVariablesWithDeterministicShellEscaping() {
    let exports = TerminalLauncher.cliEnvironmentExports(environment: [
      "B": "two words",
      "A": "quote'value",
      "C": "line1\nline2"
    ])
    let expected = """
    export A='quote'\\''value'
    export B='two words'
    export C='line1
    line2'
    """

    #expect(exports == expected)
  }

  @Test("Environment exposes AgentHub CLI and prepends its directory to PATH")
  func environmentExposesAgentHubCLI() {
    let environment = EmbeddedTerminalLaunchBuilder.makeProcessEnvironment(
      additionalPaths: ["/custom/bin"],
      agentHubCLIPath: agentHubCLIPath
    )

    #expect(environment["AGENTHUB_CLI"] == agentHubCLIPath)
    #expect(environment["PATH"]?.hasPrefix("/Applications/AgentHub.app/Contents/Helpers:") == true)
    #expect(environment["PATH"]?.contains("/custom/bin") == true)
  }

  @Test("Environment exposes AgentHub launch context")
  func environmentExposesAgentHubLaunchContext() {
    let environment = EmbeddedTerminalLaunchBuilder.makeProcessEnvironment(
      additionalPaths: [],
      agentHubCLIPath: agentHubCLIPath,
      providerKind: .claude,
      projectPath: "/tmp/project",
      sessionId: "session-123"
    )

    #expect(environment["AGENTHUB_PROVIDER"] == "Claude")
    #expect(environment["AGENTHUB_PROJECT_PATH"] == "/tmp/project")
    #expect(environment["AGENTHUB_SESSION_ID"] == "session-123")
  }

  @Test("Claude launch passes raw prompt, AgentHub MCP config, and installs worktree skill", .disabled("headless-quarantine: test-vs-code drift — JSON forward-slash escaping; see TestQuarantine.md"))
  func claudeLaunchPassesRawPromptAgentHubMCPConfigAndInstallsWorktreeSkill() throws {
    var installCount = 0
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: "/tmp",
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .claude),
      initialPrompt: "Create a worktree for the issue",
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: { installCount += 1 }
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(installCount == 1)
    #expect(launch.environment["AGENTHUB_CLI"] == agentHubCLIPath)
    #expect(launch.environment["AGENTHUB_PROVIDER"] == "Claude")
    #expect(launch.environment["AGENTHUB_PROJECT_PATH"] == "/tmp")
    #expect(launch.shellCommand.contains("--mcp-config"))
    #expect(launch.shellCommand.contains("/bin/sh"))
    #expect(launch.shellCommand.contains("mcp-server"))
    #expect(!launch.shellCommand.contains("--append-system-prompt"))
    #expect(!launch.shellCommand.contains("agenthub_create_worktree_sessions"))
    #expect(!launch.shellCommand.contains("agent_hub_planning"))
    #expect(!launch.shellCommand.contains("developer_instructions="))
    #expect(!launch.shellCommand.contains("AgentHub session context:"))
    #expect(!launch.shellCommand.contains("User request:"))
    #expect(launch.shellCommand.contains("Create a worktree for the issue"))
  }

  @Test("Blank Claude launch still passes AgentHub MCP config and installs worktree skill", .disabled("headless-quarantine: test-vs-code drift — JSON forward-slash escaping; see TestQuarantine.md"))
  func blankClaudeLaunchStillPassesAgentHubMCPConfigAndInstallsWorktreeSkill() throws {
    var installCount = 0
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: "/tmp",
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .claude),
      initialPrompt: nil,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: { installCount += 1 }
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(installCount == 1)
    #expect(launch.shellCommand.contains("--mcp-config"))
    #expect(launch.shellCommand.contains("/bin/sh"))
    #expect(launch.shellCommand.contains("mcp-server"))
    #expect(!launch.shellCommand.contains("--append-system-prompt"))
    #expect(!launch.shellCommand.contains("agenthub_create_worktree_sessions"))
    #expect(!launch.shellCommand.contains("agent_hub_planning"))
    #expect(!launch.shellCommand.contains("developer_instructions="))
    #expect(!launch.shellCommand.contains("AgentHub session context:"))
  }

  @Test("Codex launch passes AgentHub MCP config and installs worktree skill")
  func codexLaunchPassesAgentHubMCPConfigAndInstallsWorktreeSkill() throws {
    var installCount = 0
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: "/tmp",
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .codex),
      initialPrompt: nil,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: { installCount += 1 }
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(installCount == 1)
    #expect(launch.shellCommand.contains("mcp_servers.agenthub.command"))
    #expect(launch.shellCommand.contains("/bin/sh"))
    #expect(launch.shellCommand.contains("mcp-server"))
    #expect(!launch.shellCommand.contains("developer_instructions="))
    #expect(!launch.shellCommand.contains("--append-system-prompt"))
    #expect(!launch.shellCommand.contains("agenthub_create_worktree_sessions"))
    #expect(!launch.shellCommand.contains("agent_hub_planning"))
    #expect(!launch.shellCommand.contains("\\/"))
    #expect(!launch.shellCommand.contains("AgentHub session context:"))
  }

  @Test("Xcode launch passes XcodeBuildMCP bootstrap with saved simulator")
  func xcodeLaunchPassesXcodeBuildMCPBootstrapWithSavedSimulator() async throws {
    let projectRoot = try makeTemporaryDirectory(named: "AgentHubXcodeLaunch")
    defer { try? FileManager.default.removeItem(at: projectRoot) }
    let xcodeProject = projectRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: xcodeProject, withIntermediateDirectories: true)
    try "".write(
      to: xcodeProject.appendingPathComponent("project.pbxproj"),
      atomically: true,
      encoding: .utf8
    )

    let store = try SessionMetadataStore(path: temporaryDatabasePath())
    try await store.setProjectSimulatorPreference(
      ProjectSimulatorPreference(
        projectPath: projectRoot.appendingPathComponent(".").path,
        deviceIdentifier: "SIM-123",
        kind: .simulator
      )
    )

    var installCount = 0
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: projectRoot.path,
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .codex),
      initialPrompt: nil,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: store,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: { installCount += 1 },
      xcodeBuildMCPEnabled: true,
      xcodeBuildMCPToolingAvailable: { true }
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(installCount == 1)
    #expect(launch.shellCommand.contains("mcp_servers.XcodeBuildMCP.command"))
    #expect(launch.shellCommand.contains("XCODEBUILDMCP_PROJECT_PATH"))
    #expect(launch.shellCommand.contains("App.xcodeproj"))
    #expect(launch.shellCommand.contains("XCODEBUILDMCP_SIMULATOR_ID"))
    #expect(launch.shellCommand.contains("SIM-123"))
    #expect(launch.shellCommand.contains("developer_instructions="))
    #expect(launch.shellCommand.contains("XcodeBuildMCP"))
  }

  @Test("Xcode launch without Node tooling skips XcodeBuildMCP and guidance, notifies once")
  func xcodeLaunchWithoutNodeToolingSkipsXcodeBuildMCPAndNotifies() throws {
    let projectRoot = try makeTemporaryDirectory(named: "AgentHubXcodeNoNode")
    defer { try? FileManager.default.removeItem(at: projectRoot) }
    let xcodeProject = projectRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: xcodeProject, withIntermediateDirectories: true)
    try "".write(
      to: xcodeProject.appendingPathComponent("project.pbxproj"),
      atomically: true,
      encoding: .utf8
    )

    var notifyCount = 0
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: projectRoot.path,
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .codex),
      initialPrompt: nil,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: {},
      xcodeBuildMCPEnabled: true,
      xcodeBuildMCPToolingAvailable: { false },
      notifyXcodeBuildMCPToolingMissing: { notifyCount += 1 }
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(notifyCount == 1)
    #expect(!launch.shellCommand.contains("XcodeBuildMCP"))
    #expect(!launch.shellCommand.contains("developer_instructions="))
  }

  @Test("Xcode launch with XcodeBuildMCP disabled skips bootstrap, guidance, and notice")
  func xcodeLaunchWithXcodeBuildMCPDisabledSkipsBootstrapAndNotice() throws {
    let projectRoot = try makeTemporaryDirectory(named: "AgentHubXcodeDisabled")
    defer { try? FileManager.default.removeItem(at: projectRoot) }
    let xcodeProject = projectRoot.appendingPathComponent("App.xcodeproj", isDirectory: true)
    try FileManager.default.createDirectory(at: xcodeProject, withIntermediateDirectories: true)
    try "".write(
      to: xcodeProject.appendingPathComponent("project.pbxproj"),
      atomically: true,
      encoding: .utf8
    )

    var notifyCount = 0
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: projectRoot.path,
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .codex),
      initialPrompt: nil,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: {},
      xcodeBuildMCPEnabled: false,
      xcodeBuildMCPToolingAvailable: { true },
      notifyXcodeBuildMCPToolingMissing: { notifyCount += 1 }
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(notifyCount == 0)
    #expect(!launch.shellCommand.contains("XcodeBuildMCP"))
    #expect(!launch.shellCommand.contains("developer_instructions="))
  }

  @Test("Resume launch does not reinstall worktree skill")
  func resumeLaunchDoesNotReinstallWorktreeSkill() throws {
    var installCount = 0
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: "session-123",
      projectPath: "/tmp",
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .claude),
      initialPrompt: nil,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath,
      installAgentHubWorktreeSkill: { installCount += 1 }
    )

    guard case .success = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(installCount == 0)
  }

  @Test("Task manager skill installer writes Claude and Codex skill files")
  func taskManagerSkillInstallerWritesClaudeAndCodexSkillFiles() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubWorktreeSkillInstallerTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let skillMarkdown = """
    ---
    name: agenthub-task-manager
    description: Test skill
    ---

    # Test
    """
    let openAIYAML = """
    interface:
      display_name: "AgentHub Task Manager"
    policy:
      allow_implicit_invocation: false
    """

    try AgentHubWorktreeSkillInstaller.installForAllProviders(
      homeDirectory: temporaryDirectory,
      skillMarkdown: skillMarkdown,
      openAIYAML: openAIYAML
    )

    let claudeSkillURL = temporaryDirectory
      .appendingPathComponent(".claude/skills/agenthub-task-manager/SKILL.md")
    let codexSkillURL = temporaryDirectory
      .appendingPathComponent(".codex/skills/agenthub-task-manager/SKILL.md")
    let codexMetadataURL = temporaryDirectory
      .appendingPathComponent(".codex/skills/agenthub-task-manager/agents/openai.yaml")

    #expect(try String(contentsOf: claudeSkillURL, encoding: .utf8) == skillMarkdown)
    #expect(try String(contentsOf: codexSkillURL, encoding: .utf8) == skillMarkdown)
    #expect(try String(contentsOf: codexMetadataURL, encoding: .utf8) == openAIYAML)

    try "stale".write(to: codexSkillURL, atomically: true, encoding: .utf8)
    try AgentHubWorktreeSkillInstaller.installForAllProviders(
      homeDirectory: temporaryDirectory,
      skillMarkdown: skillMarkdown,
      openAIYAML: openAIYAML
    )

    #expect(try String(contentsOf: codexSkillURL, encoding: .utf8) == skillMarkdown)
  }

  @Test("Bundled task manager skill installs explicit invocation metadata")
  func bundledTaskManagerSkillInstallsExplicitInvocationMetadata() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubBundledWorktreeSkillTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    try AgentHubWorktreeSkillInstaller.installBundledSkillForAllProviders(homeDirectory: temporaryDirectory)

    let claudeSkill = try String(
      contentsOf: temporaryDirectory.appendingPathComponent(".claude/skills/agenthub-task-manager/SKILL.md"),
      encoding: .utf8
    )
    let codexSkill = try String(
      contentsOf: temporaryDirectory.appendingPathComponent(".codex/skills/agenthub-task-manager/SKILL.md"),
      encoding: .utf8
    )
    let codexMetadata = try String(
      contentsOf: temporaryDirectory.appendingPathComponent(".codex/skills/agenthub-task-manager/agents/openai.yaml"),
      encoding: .utf8
    )

    #expect(claudeSkill.contains("name: agenthub-task-manager"))
    #expect(claudeSkill.contains("user-invocable: true"))
    #expect(claudeSkill.contains("disable-model-invocation: true"))
    #expect(claudeSkill.contains("agent_hub_planning"))
    #expect(codexSkill == claudeSkill)
    #expect(codexMetadata.contains("display_name: \"AgentHub Task Manager\""))
    #expect(codexMetadata.contains("allow_implicit_invocation: false"))
  }

  private func withStandardCLIEnvironmentVariables(
    _ variables: [CLIEnvironmentVariable],
    perform: () -> Void
  ) {
    let defaults = UserDefaults.standard
    let previousData = defaults.data(forKey: AgentHubDefaults.cliEnvironmentVariables)
    CLIEnvironmentOverrides.save(variables, defaults: defaults)
    defer {
      if let previousData {
        defaults.set(previousData, forKey: AgentHubDefaults.cliEnvironmentVariables)
      } else {
        defaults.removeObject(forKey: AgentHubDefaults.cliEnvironmentVariables)
      }
    }

    perform()
  }

  private func makeTemporaryDirectory(named prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentHubLaunchBuilderTests-\(UUID().uuidString).sqlite")
      .path
  }
}
