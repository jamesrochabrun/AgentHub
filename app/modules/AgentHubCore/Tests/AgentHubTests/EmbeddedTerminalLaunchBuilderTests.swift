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

  @Test("New session prompt includes visible AgentHub CLI guidance")
  func newSessionPromptIncludesAgentHubCLIGuidance() throws {
    let prompt = try #require(AgentHubSessionInstructionBuilder.decoratedPrompt(
      "Build the login flow",
      sessionId: nil,
      agentHubCLIPath: agentHubCLIPath
    ))

    #expect(prompt.contains("AgentHub session context:"))
    #expect(prompt.contains("agenthub worktree ... --json"))
    #expect(prompt.contains("User request:\nBuild the login flow"))
  }

  @Test("Resume prompt is not decorated")
  func resumePromptIsNotDecorated() {
    let prompt = AgentHubSessionInstructionBuilder.decoratedPrompt(
      "Continue the previous task",
      sessionId: "session-123",
      agentHubCLIPath: agentHubCLIPath
    )

    #expect(prompt == "Continue the previous task")
  }

  @Test("CLI launch passes decorated prompt and AgentHub CLI environment")
  func cliLaunchPassesDecoratedPromptAndEnvironment() throws {
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
    #expect(launch.shellCommand.contains("AgentHub session context:"))
    #expect(launch.shellCommand.contains("Create a worktree for the issue"))
  }
}
