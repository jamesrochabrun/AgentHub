//
//  SimulatorPanelRunFlow.swift
//  AgentHub
//
//  Captures the Simulator side panel's full Build & Run flow (boot +
//  hot-reload plan + arm-on-launch) by reference to the long-lived controller
//  and service objects, so panel-local callbacks such as auto-run can reuse
//  the exact same path as the visible Build & Run button.
//

import Foundation
import SimulatorPreview

@MainActor
public protocol SimulatorPanelRunExecuting: AnyObject {
  func isBooted(udid: String) -> Bool
  func bootDevice(udid: String) async
  func setPreferredSimulator(udid: String?, for projectPath: String)
  func setPreferredPhysicalDevice(identifier: String?, for projectPath: String)
  func buildAndRunOnSimulator(
    udid: String,
    projectPath: String,
    hotReload: HotReloadLaunchPlan?,
    foregroundSimulatorApp: Bool
  ) async -> Bool
  func isRunInFlight(udid: String, projectPath: String) -> Bool
}

extension SimulatorService: SimulatorPanelRunExecuting {
  public func isRunInFlight(udid: String, projectPath: String) -> Bool {
    switch state(for: udid, projectPath: projectPath) {
    case .building, .installing, .launching:
      return true
    default:
      return false
    }
  }
}

/// Outcome of one panel Build & Run.
public struct SimulatorPanelRunOutcome: Equatable, Sendable {
  public let success: Bool
  /// True when the launch armed hot-reload injection, so subsequent saved
  /// Swift files hot-swap without another full run.
  public let hotReloadArmed: Bool

  public init(success: Bool, hotReloadArmed: Bool) {
    self.success = success
    self.hotReloadArmed = hotReloadArmed
  }
}

/// The panel's full simulator Build & Run flow (boot + hot-reload plan +
/// arm-on-launch) captured by reference to the long-lived controller/service
/// objects — never the SwiftUI view — so it can run outside a view update
/// without touching `@State`.
@MainActor
public struct SimulatorPanelRunFlow {
  private let simulatorService: any SimulatorPanelRunExecuting
  private let hotReload: SimulatorHotReloadController
  private let projectPath: String
  private let previewsEnabled: () -> Bool
  private let hideSimulatorAppWhileMirroring: () -> Bool
  private let simulatorAppHider: any SimulatorAppHiding

  public init(
    simulatorService: any SimulatorPanelRunExecuting,
    hotReload: SimulatorHotReloadController,
    projectPath: String,
    previewsEnabled: @escaping () -> Bool = {
      UserDefaults.standard.object(
        forKey: AgentHubDefaults.simulatorPreviewsEnabled
      ) as? Bool ?? true
    },
    hideSimulatorAppWhileMirroring: @escaping () -> Bool = {
      UserDefaults.standard.object(
        forKey: AgentHubDefaults.simulatorHideSimulatorAppWhileMirroring
      ) as? Bool ?? true
    },
    simulatorAppHider: (any SimulatorAppHiding)? = nil
  ) {
    self.simulatorService = simulatorService
    self.hotReload = hotReload
    self.projectPath = projectPath
    self.previewsEnabled = previewsEnabled
    self.hideSimulatorAppWhileMirroring = hideSimulatorAppWhileMirroring
    self.simulatorAppHider = simulatorAppHider ?? SimulatorAppHider.shared
  }

  @discardableResult
  public func run(udid: String) async -> SimulatorPanelRunOutcome {
    simulatorService.setPreferredSimulator(udid: udid, for: projectPath)
    simulatorService.setPreferredPhysicalDevice(identifier: nil, for: projectPath)
    // Boot first so the panel's preview switches to the live stream while the
    // build runs; the build's own boot is then a no-op.
    if !simulatorService.isBooted(udid: udid) {
      await simulatorService.bootDevice(udid: udid)
    }
    let plan = await hotReload.preparePlan(
      udid: udid,
      projectPath: projectPath,
      enableInjection: true,
      enablePreviews: previewsEnabled()
    )
    // The panel mirrors the device, so the real Simulator.app window stays
    // out of the way: don't bring it forward, and ⌘H-hide it if it's open.
    let hideRealSimulator = hideSimulatorAppWhileMirroring()
    let success = await simulatorService.buildAndRunOnSimulator(
      udid: udid,
      projectPath: projectPath,
      hotReload: plan,
      foregroundSimulatorApp: !hideRealSimulator
    )
    if success, let plan {
      hotReload.sessionDidLaunch(udid: udid, projectPath: projectPath, plan: plan)
    }
    if success, hideRealSimulator {
      simulatorAppHider.hideSimulatorApp()
    }
    let armed = success
      && plan?.configuration.enableInjection == true
      && plan?.configuration.artifacts.injectionDylibPath != nil
    return SimulatorPanelRunOutcome(success: success, hotReloadArmed: armed)
  }
}
