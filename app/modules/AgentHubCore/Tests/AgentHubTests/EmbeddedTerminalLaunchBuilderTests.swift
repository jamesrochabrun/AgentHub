import Foundation
import Testing

@testable import AgentHubCore

@Suite("EmbeddedTerminalLaunchBuilder AgentHub CLI context")
struct EmbeddedTerminalLaunchBuilderAgentHubCLITests {
  private let agentHubCLIPath = "/Applications/AgentHub.app/Contents/Helpers/agenthub"

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
    #expect(launch.shellCommand.contains("agenthub_create_worktree_session"))
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
    #expect(launch.shellCommand.contains("agenthub_create_worktree_session"))
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
    #expect(launch.shellCommand.contains("agenthub_create_worktree_session"))
    #expect(!launch.shellCommand.contains("\\/"))
    #expect(!launch.shellCommand.contains("AgentHub session context:"))
  }
}
