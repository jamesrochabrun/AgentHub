//
//  SimulatorAgentRunRegistry.swift
//  AgentHub
//
//  Lets an open Simulator side panel offer its full Build & Run flow (boot +
//  hot-reload plan + arm-on-launch) to agent-initiated run requests. The MCP
//  run-request handler prefers a registered panel executor so an agent-triggered
//  rebuild arms injection exactly like the user pressing Build & Run; with no
//  panel registered it falls back to a plain SimulatorService run.
//

import Foundation

/// Outcome of one agent-initiated Build & Run.
public struct SimulatorAgentRunOutcome: Equatable, Sendable {
  public let success: Bool
  /// True when the launch armed hot-reload injection, so subsequent saved
  /// Swift files hot-swap without another full run.
  public let hotReloadArmed: Bool

  public init(success: Bool, hotReloadArmed: Bool) {
    self.success = success
    self.hotReloadArmed = hotReloadArmed
  }
}

public typealias SimulatorAgentRunExecutor = @MainActor (_ udid: String) async -> SimulatorAgentRunOutcome

@MainActor
public protocol SimulatorAgentRunRegistering: AnyObject {
  func register(projectPath: String, id: UUID, executor: @escaping SimulatorAgentRunExecutor)
  func unregister(projectPath: String, id: UUID)
  func executor(forProjectPath projectPath: String) -> SimulatorAgentRunExecutor?
}

@MainActor
public final class SimulatorAgentRunRegistry: SimulatorAgentRunRegistering {
  public static let shared = SimulatorAgentRunRegistry()

  private struct Registration {
    let id: UUID
    let executor: SimulatorAgentRunExecutor
  }

  private var registrations: [String: Registration] = [:]

  public init() {}

  public func register(
    projectPath: String,
    id: UUID,
    executor: @escaping SimulatorAgentRunExecutor
  ) {
    registrations[SimulatorProjectPathNormalizer.normalize(projectPath)] =
      Registration(id: id, executor: executor)
  }

  /// Removes the registration only when it still belongs to `id`, so a panel
  /// closing late never tears down a newer panel's executor.
  public func unregister(projectPath: String, id: UUID) {
    let key = SimulatorProjectPathNormalizer.normalize(projectPath)
    guard registrations[key]?.id == id else { return }
    registrations[key] = nil
  }

  public func executor(forProjectPath projectPath: String) -> SimulatorAgentRunExecutor? {
    registrations[SimulatorProjectPathNormalizer.normalize(projectPath)]?.executor
  }
}

/// The panel's full simulator Build & Run flow (boot + hot-reload plan +
/// arm-on-launch) captured by reference to the long-lived controller/service
/// objects — never the SwiftUI view — so it can be handed to the registry and
/// to auto-run callbacks without touching view state from outside a body.
@MainActor
public struct SimulatorPanelRunFlow {
  private let simulatorService: any SimulatorRunExecuting
  private let hotReload: SimulatorHotReloadController
  private let projectPath: String
  private let previewsEnabled: () -> Bool
  private let hideSimulatorAppWhileMirroring: () -> Bool
  private let simulatorAppHider: any SimulatorAppHiding

  public init(
    simulatorService: any SimulatorRunExecuting,
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
  public func run(udid: String) async -> SimulatorAgentRunOutcome {
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
    return SimulatorAgentRunOutcome(success: success, hotReloadArmed: armed)
  }
}

/// Shared normalization so panel registrations and agent requests agree on
/// the same project key regardless of `~`, trailing slashes, or `..` segments.
public enum SimulatorProjectPathNormalizer {
  public static func normalize(_ path: String) -> String {
    var normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .standardizedFileURL
      .path
    while normalized.count > 1 && normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    return normalized
  }
}
