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
    let handler = SimulatorRunRequestHandler(simulatorService: executor)

    try await handler.handle(SimulatorRunRequest(
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
    let handler = SimulatorRunRequestHandler(simulatorService: executor)

    try await handler.handle(SimulatorRunRequest(projectPath: "/tmp/App", udid: "UDID-1"))

    #expect(executor.bootedUDIDs.isEmpty)
    #expect(executor.buildRequests.count == 1)
  }

  @Test("Handler throws when Build and Run fails")
  func handlerThrowsWhenBuildFails() async {
    let executor = MockSimulatorRunExecutor(isBooted: true, buildResult: false)
    let handler = SimulatorRunRequestHandler(simulatorService: executor)

    await #expect(throws: SimulatorRunRequestHandlingError.runFailed(projectPath: "/tmp/App", udid: "UDID-1")) {
      try await handler.handle(SimulatorRunRequest(projectPath: "/tmp/App", udid: "UDID-1"))
    }
  }
}

@MainActor
private final class MockSimulatorRunExecutor: SimulatorRunExecuting {
  struct BuildRequest: Equatable {
    let udid: String
    let projectPath: String
    let hotReloadWasProvided: Bool
  }

  private let booted: Bool
  private let buildResult: Bool
  var bootedUDIDs: [String] = []
  var buildRequests: [BuildRequest] = []

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
    hotReload: HotReloadLaunchPlan?
  ) async -> Bool {
    buildRequests.append(BuildRequest(
      udid: udid,
      projectPath: projectPath,
      hotReloadWasProvided: hotReload != nil
    ))
    return buildResult
  }
}
