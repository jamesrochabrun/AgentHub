import Foundation
import Testing

@testable import AgentHubCore

@Suite("EmbeddedTerminalLaunchBuilder AgentHub CLI context", .serialized)
struct EmbeddedTerminalLaunchBuilderAgentHubCLITests {
  private let agentHubCLIPath = "/Applications/AgentHub.app/Contents/Helpers/agenthub"

  @Test("CLI environment variables are empty by default")
  func cliEnvironmentVariablesAreEmptyByDefault() {
    let suiteName = "AgentHubTests.CLIEnvironment.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

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
    let suiteName = "AgentHubTests.CLIEnvironment.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

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

  @Test("Claude launch passes raw prompt, AgentHub MCP config, and hidden routing instruction")
  func claudeLaunchPassesRawPromptAgentHubMCPConfigAndRoutingInstruction() throws {
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: "/tmp",
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .claude),
      initialPrompt: "Create a worktree for the issue",
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(launch.environment["AGENTHUB_CLI"] == agentHubCLIPath)
    #expect(launch.environment["AGENTHUB_PROVIDER"] == "Claude")
    #expect(launch.environment["AGENTHUB_PROJECT_PATH"] == "/tmp")
    #expect(launch.shellCommand.contains("--mcp-config"))
    #expect(launch.shellCommand.contains("/bin/sh"))
    #expect(launch.shellCommand.contains("mcp-server"))
    #expect(launch.shellCommand.contains("--append-system-prompt"))
    #expect(launch.shellCommand.contains("agenthub_create_worktree_sessions"))
    #expect(launch.shellCommand.contains("For worktree creation you MUST use the AgentHub tool first"))
    #expect(launch.shellCommand.contains("agenthub_list_worktrees"))
    #expect(launch.shellCommand.contains("agenthub_delete_worktree"))
    #expect(!launch.shellCommand.contains("AgentHub session context:"))
    #expect(!launch.shellCommand.contains("User request:"))
    #expect(launch.shellCommand.contains("Create a worktree for the issue"))
  }

  @Test("Blank Claude launch still passes AgentHub MCP config")
  func blankClaudeLaunchStillPassesAgentHubMCPConfig() throws {
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: "/tmp",
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .claude),
      initialPrompt: nil,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(launch.shellCommand.contains("--mcp-config"))
    #expect(launch.shellCommand.contains("/bin/sh"))
    #expect(launch.shellCommand.contains("mcp-server"))
    #expect(launch.shellCommand.contains("--append-system-prompt"))
    #expect(launch.shellCommand.contains("agenthub_create_worktree_sessions"))
    #expect(launch.shellCommand.contains("For worktree creation you MUST use the AgentHub tool first"))
    #expect(launch.shellCommand.contains("agenthub_list_worktrees"))
    #expect(launch.shellCommand.contains("agenthub_delete_worktree"))
    #expect(!launch.shellCommand.contains("AgentHub session context:"))
  }

  @Test("Codex launch passes AgentHub MCP config and routing instruction")
  func codexLaunchPassesAgentHubMCPConfigAndRoutingInstruction() throws {
    let result = EmbeddedTerminalLaunchBuilder.cliLaunch(
      sessionId: nil,
      projectPath: "/tmp",
      cliConfiguration: CLICommandConfiguration(command: "echo", additionalPaths: ["/bin"], mode: .codex),
      initialPrompt: nil,
      dangerouslySkipPermissions: false,
      permissionModePlan: false,
      worktreeName: nil,
      metadataStore: nil,
      agentHubCLIPath: agentHubCLIPath
    )

    guard case .success(let launch) = result else {
      Issue.record("Expected launch builder success")
      return
    }

    #expect(launch.shellCommand.contains("mcp_servers.agenthub.command"))
    #expect(launch.shellCommand.contains("/bin/sh"))
    #expect(launch.shellCommand.contains("mcp-server"))
    #expect(launch.shellCommand.contains("developer_instructions="))
    #expect(launch.shellCommand.contains("agenthub_create_worktree_sessions"))
    #expect(launch.shellCommand.contains("For worktree creation you MUST use the AgentHub tool first"))
    #expect(launch.shellCommand.contains("agenthub_list_worktrees"))
    #expect(launch.shellCommand.contains("agenthub_delete_worktree"))
    #expect(!launch.shellCommand.contains("\\/"))
    #expect(!launch.shellCommand.contains("AgentHub session context:"))
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
}
