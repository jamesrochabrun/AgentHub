import AgentHubCLIKit
import Foundation
import SimulatorPreview
import Testing

@testable import AgentHubCore

@Suite("SimulatorRunRequestHandler")
@MainActor
struct SimulatorRunRequestHandlerTests {
  @Test("Handler boots target simulator before Build and Run")
  func handlerBootsBeforeBuildAndRun() async throws {
    let executor = MockSimulatorRunExecutor(isBooted: false, buildResult: true)
    let context = try HandlerContext(executor: executor)

    try await context.handler.handle(SimulatorRunRequest(
      projectPath: "/tmp/App",
      udid: "UDID-1",
      reason: "verify"
    ))

    #expect(executor.bootedUDIDs == ["UDID-1"])
    #expect(executor.buildRequests == [MockSimulatorRunExecutor.BuildRequest(
      udid: "UDID-1",
      projectPath: "/tmp/App",
      hotReloadWasProvided: false
    )])
  }

  @Test("Handler skips boot for already booted simulator")
  func handlerSkipsBootForBootedSimulator() async throws {
    let executor = MockSimulatorRunExecutor(isBooted: true, buildResult: true)
    let context = try HandlerContext(executor: executor)

    try await context.handler.handle(SimulatorRunRequest(projectPath: "/tmp/App", udid: "UDID-1"))

    #expect(executor.bootedUDIDs.isEmpty)
    #expect(executor.buildRequests.count == 1)
  }

  @Test("Handler throws and records failure result when Build and Run fails")
  func handlerThrowsWhenBuildFails() async throws {
    let executor = MockSimulatorRunExecutor(isBooted: true, buildResult: false)
    executor.failureMessage = "error: type 'Foo' has no member 'bar'"
    let context = try HandlerContext(executor: executor)
    let request = SimulatorRunRequest(projectPath: "/tmp/App", udid: "UDID-1")

    await #expect(throws: SimulatorRunRequestHandlingError.runFailed(
      projectPath: "/tmp/App",
      udid: "UDID-1",
      message: "error: type 'Foo' has no member 'bar'"
    )) {
      try await context.handler.handle(request)
    }

    let result = context.resultStore.result(requestId: request.id)
    #expect(result?.status == .failed)
    #expect(result?.errorMessage?.contains("type 'Foo' has no member 'bar'") == true)
  }

  @Test("Handler records success result readable by the MCP server")
  func handlerRecordsSuccessResult() async throws {
    let executor = MockSimulatorRunExecutor(isBooted: true, buildResult: true)
    let context = try HandlerContext(executor: executor)
    let request = SimulatorRunRequest(projectPath: "/tmp/App", udid: "UDID-1")

    try await context.handler.handle(request)

    let result = context.resultStore.result(requestId: request.id)
    #expect(result?.status == .succeeded)
    #expect(result?.udid == "UDID-1")
    #expect(result?.hotReloadArmed == false)
  }

  @Test("Handler resolves the project's preferred simulator when the request omits a udid")
  func handlerResolvesPreferredSimulator() async throws {
    let executor = MockSimulatorRunExecutor(isBooted: true, buildResult: true)
    executor.preferredUDIDsByProject = ["/tmp/App": "UDID-PREFERRED"]
    let context = try HandlerContext(executor: executor)
    let request = SimulatorRunRequest(projectPath: "/tmp/App")

    try await context.handler.handle(request)

    #expect(executor.buildRequests.map(\.udid) == ["UDID-PREFERRED"])
    #expect(context.resultStore.result(requestId: request.id)?.udid == "UDID-PREFERRED")
  }

  @Test("Handler fails with guidance when no destination is configured")
  func handlerFailsWithoutDestination() async throws {
    let executor = MockSimulatorRunExecutor(isBooted: true, buildResult: true)
    let context = try HandlerContext(executor: executor)
    let request = SimulatorRunRequest(projectPath: "/tmp/App")

    await #expect(throws: SimulatorRunRequestHandlingError.noRunDestination(projectPath: "/tmp/App")) {
      try await context.handler.handle(request)
    }

    let result = context.resultStore.result(requestId: request.id)
    #expect(result?.status == .failed)
    #expect(result?.errorMessage?.contains("Run Destination") == true)
    #expect(executor.buildRequests.isEmpty)
  }

  @Test("Handler routes through a registered panel executor and reports armed hot reload")
  func handlerPrefersPanelExecutor() async throws {
    let executor = MockSimulatorRunExecutor(isBooted: true, buildResult: false)
    var panelRunUDIDs: [String] = []
    let context = try HandlerContext(
      executor: executor,
      panelExecutorResolver: { projectPath in
        guard projectPath == "/tmp/App" else { return nil }
        return { udid in
          panelRunUDIDs.append(udid)
          return SimulatorAgentRunOutcome(success: true, hotReloadArmed: true)
        }
      }
    )
    let request = SimulatorRunRequest(projectPath: "/tmp/App", udid: "UDID-1")

    try await context.handler.handle(request)

    #expect(panelRunUDIDs == ["UDID-1"])
    #expect(executor.buildRequests.isEmpty)
    #expect(context.resultStore.result(requestId: request.id)?.hotReloadArmed == true)
  }

  @Test("Handler waits for an in-flight run to settle before building")
  func handlerWaitsForInFlightRun() async throws {
    let executor = MockSimulatorRunExecutor(isBooted: true, buildResult: true)
    executor.inFlightChecksBeforeSettled = 3
    let context = try HandlerContext(executor: executor)

    try await context.handler.handle(SimulatorRunRequest(projectPath: "/tmp/App", udid: "UDID-1"))

    #expect(executor.inFlightChecks >= 3)
    #expect(executor.buildRequests.count == 1)
  }
}

/// Bundles a handler with an isolated on-disk result store per test.
@MainActor
private struct HandlerContext {
  let handler: SimulatorRunRequestHandler
  let resultStore: SimulatorRunResultStore

  init(
    executor: MockSimulatorRunExecutor,
    panelExecutorResolver: ((String) -> SimulatorAgentRunExecutor?)? = { _ in nil }
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agenthub-run-handler-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    resultStore = SimulatorRunResultStore(directoryURL: directory)
    handler = SimulatorRunRequestHandler(
      simulatorService: executor,
      resultStore: resultStore,
      panelExecutorResolver: panelExecutorResolver,
      inFlightPollInterval: .milliseconds(5),
      inFlightWaitLimit: .seconds(2)
    )
  }
}

@MainActor
private final class MockSimulatorRunExecutor: SimulatorRunExecuting {
  struct BuildRequest: Equatable {
    let udid: String
    let projectPath: String
    let hotReloadWasProvided: Bool
    var foregroundSimulatorApp = true
  }

  private let booted: Bool
  private let buildResult: Bool
  var bootedUDIDs: [String] = []
  var buildRequests: [BuildRequest] = []
  var preferredUDIDsByProject: [String: String] = [:]
  var failureMessage: String?
  var inFlightChecksBeforeSettled = 0
  var inFlightChecks = 0

  init(isBooted: Bool, buildResult: Bool) {
    self.booted = isBooted
    self.buildResult = buildResult
  }

  func isBooted(udid: String) -> Bool {
    booted
  }

  func bootDevice(udid: String) async {
    bootedUDIDs.append(udid)
  }

  func buildAndRunOnSimulator(
    udid: String,
    projectPath: String,
    hotReload: HotReloadLaunchPlan?,
    foregroundSimulatorApp: Bool
  ) async -> Bool {
    buildRequests.append(BuildRequest(
      udid: udid,
      projectPath: projectPath,
      hotReloadWasProvided: hotReload != nil,
      foregroundSimulatorApp: foregroundSimulatorApp
    ))
    return buildResult
  }

  func ensurePreferencesLoaded() async {}

  func preferredSimulatorUDID(forProjectPath projectPath: String) -> String? {
    preferredUDIDsByProject[projectPath]
  }

  func isRunInFlight(udid: String, projectPath: String) -> Bool {
    inFlightChecks += 1
    return inFlightChecks <= inFlightChecksBeforeSettled
  }

  func buildFailureMessage(udid: String, projectPath: String) -> String? {
    failureMessage
  }
}
