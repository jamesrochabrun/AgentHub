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
    hotReload: HotReloadLaunchPlan?
  ) async -> Bool
}

extension SimulatorService: SimulatorRunExecuting {}

enum SimulatorRunRequestHandlingError: LocalizedError, Equatable {
  case invalidTarget
  case runFailed(projectPath: String, udid: String)

  var errorDescription: String? {
    switch self {
    case .invalidTarget:
      return "Simulator run request is missing a project path or UDID."
    case .runFailed(let projectPath, let udid):
      return "Simulator Build & Run failed for \(projectPath) on \(udid)."
    }
  }
}

@MainActor
public final class SimulatorRunRequestHandler: SimulatorRunRequestHandlingProtocol {
  private let simulatorService: any SimulatorRunExecuting

  public init(simulatorService: any SimulatorRunExecuting = SimulatorService.shared) {
    self.simulatorService = simulatorService
  }

  public func handle(_ request: SimulatorRunRequest) async throws {
    let projectPath = request.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let udid = request.udid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !projectPath.isEmpty, !udid.isEmpty else {
      throw SimulatorRunRequestHandlingError.invalidTarget
    }

    if !simulatorService.isBooted(udid: udid) {
      await simulatorService.bootDevice(udid: udid)
    }

    let success = await simulatorService.buildAndRunOnSimulator(
      udid: udid,
      projectPath: projectPath,
      hotReload: nil
    )
    guard success else {
      throw SimulatorRunRequestHandlingError.runFailed(projectPath: projectPath, udid: udid)
    }
  }
}
