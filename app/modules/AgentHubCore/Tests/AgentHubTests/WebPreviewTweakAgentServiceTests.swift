import Foundation
import Testing
import Canvas

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
    cliConfiguration: CLICommandConfiguration,
    activityHandler: @Sendable @escaping () async -> Void
  ) async throws {
    self.prompt = prompt
    self.workingDirectory = workingDirectory
    await activityHandler()
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
      inactivityTimeout: .seconds(1)
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

@Suite("TweakAgentProgressTimeout")
struct TweakAgentProgressTimeoutTests {
  @Test("Times out only after the inactivity interval")
  func timesOutAfterInactivity() {
    let start = ContinuousClock.now
    var timeout = TweakAgentProgressTimeout(
      interval: .seconds(300),
      initialActivity: 1,
      now: start
    )

    let didTimeOutBeforeInterval = timeout.hasTimedOut(activity: 1, now: start.advanced(by: .seconds(299)))
    let didTimeOutAtInterval = timeout.hasTimedOut(activity: 1, now: start.advanced(by: .seconds(300)))

    #expect(!didTimeOutBeforeInterval)
    #expect(didTimeOutAtInterval)
  }

  @Test("Progress resets the inactivity interval")
  func progressResetsTimeout() {
    let start = ContinuousClock.now
    var timeout = TweakAgentProgressTimeout(
      interval: .seconds(300),
      initialActivity: 1,
      now: start
    )

    let didTimeOutOnProgress = timeout.hasTimedOut(activity: 2, now: start.advanced(by: .seconds(290)))
    let didTimeOutBeforeResetInterval = timeout.hasTimedOut(activity: 2, now: start.advanced(by: .seconds(589)))
    let didTimeOutAtResetInterval = timeout.hasTimedOut(activity: 2, now: start.advanced(by: .seconds(590)))

    #expect(!didTimeOutOnProgress)
    #expect(!didTimeOutBeforeResetInterval)
    #expect(didTimeOutAtResetInterval)
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

@Suite("TweakGenerationBanner")
struct TweakGenerationBannerTests {
  @Test("Explains that generation can take a few minutes")
  func messageSetsTimingExpectation() {
    #expect(TweakGenerationBanner.message == "Tweaks are being generated. This can take a few minutes.")
  }

  @Test("Formats elapsed generation time")
  func formatsElapsedTime() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    #expect(TweakGenerationBanner.elapsedTime(from: start, to: start.addingTimeInterval(65)) == "1:05")
    #expect(TweakGenerationBanner.elapsedTime(from: start, to: start.addingTimeInterval(3_661)) == "1:01:01")
    #expect(TweakGenerationBanner.elapsedTime(from: start, to: start.addingTimeInterval(-1)) == "0:00")
  }
}

@Suite("TweakGenerationTimer")
struct TweakGenerationTimerTests {
  @Test("Keeps the generation start time until work stops")
  func lifecycle() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    var timer = TweakGenerationTimer()

    timer.start(at: start)
    #expect(timer.startedAt == start)

    timer.stop()
    #expect(timer.startedAt == nil)
  }
}

@Suite("TweakPanelStatusRouting")
struct TweakPanelStatusRoutingTests {
  @Test("Canvas does not duplicate host agent status", arguments: [
    TweaksAgentState.idle,
    .working,
    .failed("Failure"),
    .conflict,
  ])
  func canvasAgentStatusIsIdle(state: TweaksAgentState) {
    #expect(TweakPanelStatusRouting.canvasAgentState(for: state) == .idle)
  }

  @Test("Canvas retains only the defaults saving state")
  func canvasDefaultsStatus() {
    #expect(TweakPanelStatusRouting.canvasDefaultsState(for: .idle) == .idle)
    #expect(TweakPanelStatusRouting.canvasDefaultsState(for: .saving) == .saving)
    #expect(TweakPanelStatusRouting.canvasDefaultsState(for: .failed("Failure")) == .idle)
  }

  @Test("Host status appears only for visible status content")
  func hostStatusVisibility() {
    #expect(!TweakPanelStatusRouting.showsHostStatus(agentState: .idle, defaultsState: .idle))
    #expect(!TweakPanelStatusRouting.showsHostStatus(agentState: .idle, defaultsState: .saving))
    #expect(TweakPanelStatusRouting.showsHostStatus(agentState: .working, defaultsState: .idle))
    #expect(TweakPanelStatusRouting.showsHostStatus(agentState: .failed("Failure"), defaultsState: .idle))
    #expect(TweakPanelStatusRouting.showsHostStatus(agentState: .idle, defaultsState: .failed("Failure")))
  }
}
