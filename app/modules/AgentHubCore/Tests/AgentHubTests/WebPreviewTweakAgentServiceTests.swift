import Foundation
import Testing

@testable import AgentHubCore

private actor TweakAgentMockWorkspaceCoordinator: TweakWorkspaceCoordinating {
  private(set) var finishedPolicy: InspectorTweakPolicy?
  private(set) var didDiscard = false

  func prepare(targetFileURL: URL) async throws -> TweakWorkspaceTransaction {
    TweakWorkspaceTransaction(
      rootURL: URL(fileURLWithPath: "/tmp/tweak-task"),
      workingFileURL: URL(fileURLWithPath: "/tmp/tweak-task/index.html"),
      targetFileURL: targetFileURL,
      baseContents: Data()
    )
  }

  func finish(
    _ transaction: TweakWorkspaceTransaction,
    policy: InspectorTweakPolicy
  ) async throws -> InspectorTweakResult {
    finishedPolicy = policy
    return .applied
  }

  func discard(_ transaction: TweakWorkspaceTransaction) async {
    didDiscard = true
  }
}

private actor TweakAgentMockCommandRunner: TweakAgentCommandRunning {
  private(set) var prompt: String?
  private(set) var workingDirectory: String?

  func run(
    prompt: String,
    systemPrompt: String,
    workingDirectory: String,
    cliConfiguration: CLICommandConfiguration
  ) async throws {
    self.prompt = prompt
    self.workingDirectory = workingDirectory
  }
}

@Suite("WebPreviewTweakAgentService")
struct WebPreviewTweakAgentServiceTests {
  @Test("Runs in the isolated workspace and finishes with the requested policy")
  func runsIsolatedTransaction() async throws {
    let workspace = TweakAgentMockWorkspaceCoordinator()
    let runner = TweakAgentMockCommandRunner()
    let service = WebPreviewTweakAgentService(
      workspaceCoordinator: workspace,
      commandRunner: runner,
      timeout: .seconds(1)
    )

    let result = try await service.runTweakAgent(
      prompt: "Add warmth",
      targetFileURL: URL(fileURLWithPath: "/project/index.html"),
      policy: .additive,
      cliConfiguration: .codexDefault
    )

    #expect(result == .applied)
    #expect(await runner.prompt == "Add warmth")
    #expect(await runner.workingDirectory == "/tmp/tweak-task")
    #expect(await workspace.finishedPolicy == .additive)
    #expect(await workspace.didDiscard == false)
  }
}

@Suite("TweakAgentProcessRunner command arguments")
struct TweakAgentProcessRunnerTests {
  @Test("Builds an ephemeral Claude edit command")
  func buildsClaudeCommand() {
    let arguments = TweakAgentProcessRunner.arguments(
      prompt: "Add warmth",
      systemPrompt: "Edit one file",
      workingDirectory: "/tmp/task",
      cliConfiguration: CLICommandConfiguration(
        command: "agenthub claude",
        mode: .claude,
        extraArgs: ["--model", "sonnet"]
      )
    )

    #expect(arguments.starts(with: ["claude", "--model", "sonnet", "-p"]))
    #expect(arguments.contains("--no-session-persistence"))
    #expect(arguments.contains("acceptEdits"))
    #expect(arguments.last == "Add warmth")
  }

  @Test("Builds an ephemeral Codex workspace-write command")
  func buildsCodexCommand() {
    let arguments = TweakAgentProcessRunner.arguments(
      prompt: "Add warmth",
      systemPrompt: "Edit one file",
      workingDirectory: "/tmp/task",
      cliConfiguration: CLICommandConfiguration(command: "codex", mode: .codex)
    )

    #expect(arguments.first == "exec")
    #expect(arguments.contains("--ephemeral"))
    #expect(arguments.contains("workspace-write"))
    #expect(arguments.contains("/tmp/task"))
    #expect(arguments.last?.contains("Add warmth") == true)
  }
}

@Suite("TweaksButtonPresentation")
struct TweaksButtonPresentationTests {
  @Test("Working state shows progress")
  func workingStateShowsProgress() {
    let presentation = TweaksButtonPresentation.resolve(agentState: .working)
    #expect(presentation.isLoading)
    #expect(presentation.accessibilityLabel == "Creating tweaks")
  }

  @Test("Idle state uses the standard label")
  func idleStateUsesStandardLabel() {
    let presentation = TweaksButtonPresentation.resolve(agentState: .idle)
    #expect(!presentation.isLoading)
    #expect(presentation.accessibilityLabel == "Tweaks")
  }
}
