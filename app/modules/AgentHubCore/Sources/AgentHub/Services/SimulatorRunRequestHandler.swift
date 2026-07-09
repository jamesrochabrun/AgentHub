import AgentHubCLIKit
import Foundation
import SimulatorPreview

@MainActor
public protocol SimulatorRunRequestHandlingProtocol: AnyObject {
  func handle(_ request: SimulatorRunRequest) async throws
}

@MainActor
public protocol SimulatorRunExecuting: AnyObject {
  func isBooted(udid: String) -> Bool
  func bootDevice(udid: String) async
  func buildAndRunOnSimulator(
    udid: String,
    projectPath: String,
    hotReload: HotReloadLaunchPlan?,
    foregroundSimulatorApp: Bool
  ) async -> Bool
  func ensurePreferencesLoaded() async
  func preferredSimulatorUDID(forProjectPath projectPath: String) -> String?
  func isRunInFlight(udid: String, projectPath: String) -> Bool
  func buildFailureMessage(udid: String, projectPath: String) -> String?
}

extension SimulatorService: SimulatorRunExecuting {
  public func preferredSimulatorUDID(forProjectPath projectPath: String) -> String? {
    if let exact = preferredSimulatorUDIDs[projectPath] {
      return exact
    }
    let normalized = SimulatorProjectPathNormalizer.normalize(projectPath)
    return preferredSimulatorUDIDs.first {
      SimulatorProjectPathNormalizer.normalize($0.key) == normalized
    }?.value
  }

  public func isRunInFlight(udid: String, projectPath: String) -> Bool {
    switch state(for: udid, projectPath: projectPath) {
    case .building, .installing, .launching:
      return true
    default:
      return false
    }
  }

  public func buildFailureMessage(udid: String, projectPath: String) -> String? {
    if case .failed(let message) = state(for: udid, projectPath: projectPath) {
      return message
    }
    return nil
  }
}

enum SimulatorRunRequestHandlingError: LocalizedError, Equatable {
  case invalidTarget
  case noRunDestination(projectPath: String)
  case runFailed(projectPath: String, udid: String, message: String?)

  var errorDescription: String? {
    switch self {
    case .invalidTarget:
      return "Simulator run request is missing a project path."
    case .noRunDestination(let projectPath):
      return "No simulator run destination is configured for \(projectPath). Pick a Run Destination in AgentHub's Simulator panel once, or pass an explicit simulator udid."
    case .runFailed(let projectPath, let udid, let message):
      let detail = message.map { ": \($0)" } ?? "."
      return "Simulator Build & Run failed for \(projectPath) on \(udid)\(detail)"
    }
  }
}

@MainActor
public final class SimulatorRunRequestHandler: SimulatorRunRequestHandlingProtocol {
  private let simulatorService: any SimulatorRunExecuting
  private let resultStore: SimulatorRunResultStore
  private let panelExecutorResolver: (String) -> SimulatorAgentRunExecutor?
  private let inFlightPollInterval: Duration
  private let inFlightWaitLimit: Duration

  public init(
    simulatorService: any SimulatorRunExecuting = SimulatorService.shared,
    resultStore: SimulatorRunResultStore = SimulatorRunResultStore(),
    panelExecutorResolver: ((String) -> SimulatorAgentRunExecutor?)? = nil,
    inFlightPollInterval: Duration = .seconds(1),
    inFlightWaitLimit: Duration = .seconds(600)
  ) {
    self.simulatorService = simulatorService
    self.resultStore = resultStore
    self.panelExecutorResolver = panelExecutorResolver
      ?? { SimulatorAgentRunRegistry.shared.executor(forProjectPath: $0) }
    self.inFlightPollInterval = inFlightPollInterval
    self.inFlightWaitLimit = inFlightWaitLimit
  }

  public func handle(_ request: SimulatorRunRequest) async throws {
    let projectPath = request.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !projectPath.isEmpty else {
      try? writeResult(for: request, status: .failed, projectPath: request.projectPath,
                       udid: nil, error: SimulatorRunRequestHandlingError.invalidTarget)
      throw SimulatorRunRequestHandlingError.invalidTarget
    }

    let udid: String
    do {
      udid = try await resolveUDID(for: request, projectPath: projectPath)
    } catch {
      try? writeResult(for: request, status: .failed, projectPath: projectPath,
                       udid: nil, error: error)
      throw error
    }

    // A build already mid-flight for this device+project (the user's own
    // Build & Run, or a previous request) must finish first — two concurrent
    // xcodebuilds would fight over the same derived data.
    await waitForInFlightRunToSettle(udid: udid, projectPath: projectPath)

    if !simulatorService.isBooted(udid: udid) {
      await simulatorService.bootDevice(udid: udid)
    }

    // Prefer the open panel's executor: it launches with the hot-reload plan
    // and arms injection, so the agent's next file saves hot-swap in place.
    let outcome: SimulatorAgentRunOutcome
    if let panelRun = panelExecutorResolver(projectPath) {
      outcome = await panelRun(udid)
    } else {
      // No panel is mirroring, so the real Simulator.app window is the only
      // place the user can see the app — bring it forward as before.
      let success = await simulatorService.buildAndRunOnSimulator(
        udid: udid,
        projectPath: projectPath,
        hotReload: nil,
        foregroundSimulatorApp: true
      )
      outcome = SimulatorAgentRunOutcome(success: success, hotReloadArmed: false)
    }

    guard outcome.success else {
      let message = simulatorService.buildFailureMessage(udid: udid, projectPath: projectPath)
      let error = SimulatorRunRequestHandlingError.runFailed(
        projectPath: projectPath, udid: udid, message: message
      )
      try? writeResult(for: request, status: .failed, projectPath: projectPath,
                       udid: udid, error: error)
      throw error
    }

    try? writeResult(for: request, status: .succeeded, projectPath: projectPath,
                     udid: udid, hotReloadArmed: outcome.hotReloadArmed)
  }

  private func resolveUDID(
    for request: SimulatorRunRequest,
    projectPath: String
  ) async throws -> String {
    if let requested = request.udid?.trimmingCharacters(in: .whitespacesAndNewlines),
       !requested.isEmpty
    {
      return requested
    }
    await simulatorService.ensurePreferencesLoaded()
    guard let preferred = simulatorService.preferredSimulatorUDID(forProjectPath: projectPath)
    else {
      throw SimulatorRunRequestHandlingError.noRunDestination(projectPath: projectPath)
    }
    return preferred
  }

  private func waitForInFlightRunToSettle(udid: String, projectPath: String) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: inFlightWaitLimit)
    while simulatorService.isRunInFlight(udid: udid, projectPath: projectPath),
          clock.now < deadline, !Task.isCancelled
    {
      try? await Task.sleep(for: inFlightPollInterval)
    }
  }

  private func writeResult(
    for request: SimulatorRunRequest,
    status: SimulatorRunResult.Status,
    projectPath: String,
    udid: String?,
    hotReloadArmed: Bool = false,
    error: Error? = nil
  ) throws {
    try resultStore.write(SimulatorRunResult(
      requestId: request.id,
      status: status,
      projectPath: projectPath,
      udid: udid,
      errorMessage: error?.localizedDescription,
      hotReloadArmed: hotReloadArmed
    ))
  }
}
