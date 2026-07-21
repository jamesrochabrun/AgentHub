//
//  SimulatorService.swift
//  AgentHub
//
//  Manages iOS Simulator lifecycle: listing devices, booting, shutting down.
//  Mirrors the DevServerManager pattern — @MainActor @Observable singleton
//  with UDID-keyed state and Task.detached for all process execution.
//

import CryptoKit
import Foundation
import SimulatorPreview

// MARK: - Private Build Helpers

/// Holds a running xcodebuild Process so it can be terminated from the main actor.
private final class ProcessRef: @unchecked Sendable {
  let process: Process
  let outputPipe: Pipe
  let errorPipe: Pipe

  init(process: Process, outputPipe: Pipe, errorPipe: Pipe) {
    self.process = process
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe
  }
}

final class BuildOutputAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private let maxBytes: Int
  private var buffer = Data()

  init(maxBytes: Int = 1_048_576) {
    self.maxBytes = Swift.max(0, maxBytes)
  }

  func append(_ chunk: Data) {
    guard !chunk.isEmpty, maxBytes > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    if chunk.count >= maxBytes {
      buffer = Data(chunk.suffix(maxBytes))
    } else {
      buffer.append(chunk)
      let overflow = buffer.count - maxBytes
      if overflow > 0 {
        buffer.removeFirst(overflow)
      }
    }
  }

  func combinedData() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return buffer
  }
}

private struct ProcessExecutionResult: Sendable {
  let exitCode: Int32
  let outputText: String
  let errorText: String
}

/// Result of the detection phase — workspace/project path, scheme, and xcodebuild path.
private struct BuildSetup: Sendable {
  let targetPath: String
  let isWorkspace: Bool
  let scheme: String
  let xcodebuild: String
  let derivedDataPath: String

  func withDerivedDataPath(_ path: String) -> BuildSetup {
    BuildSetup(
      targetPath: targetPath,
      isWorkspace: isWorkspace,
      scheme: scheme,
      xcodebuild: xcodebuild,
      derivedDataPath: path
    )
  }
}

struct BuiltAppInfo: Sendable {
  let appPath: String
  let bundleIdentifier: String?
}

enum BuildPlatform {
  case macOS
  case iOSSimulator
  case iOSDevice

  var productsDirectoryName: String {
    switch self {
    case .macOS:
      return "Debug"
    case .iOSSimulator:
      return "Debug-iphonesimulator"
    case .iOSDevice:
      return "Debug-iphoneos"
    }
  }

  func scoreProductPathComponents(_ components: [String]) -> Int? {
    let lowercased = components.map { $0.lowercased() }

    switch self {
    case .macOS:
      let excludedFragments = [
        "iphoneos",
        "iphonesimulator",
        "appletvos",
        "appletvsimulator",
        "watchos",
        "watchsimulator",
        "xros",
        "xrsimulator"
      ]
      if lowercased.contains(where: { component in
        excludedFragments.contains(where: component.contains)
      }) {
        return nil
      }

      if lowercased.contains(where: { $0.contains("macosx") || $0.contains("maccatalyst") }) {
        return 30
      }
      if lowercased.contains(where: { $0 == "debug" || $0 == "release" }) {
        return 20
      }
      return 10
    case .iOSSimulator:
      guard lowercased.contains(where: { $0.contains("iphonesimulator") }) else {
        return nil
      }
      return 30
    case .iOSDevice:
      guard lowercased.contains(where: { $0.contains("iphoneos") }) else {
        return nil
      }
      return 30
    }
  }
}

// MARK: - SimulatorService

/// Manages iOS Simulator devices globally.
///
/// State is UDID-keyed so multiple session cards share the same device state —
/// if one card boots a simulator all other cards observing that UDID update instantly.
@MainActor
@Observable
public final class SimulatorService {

  // MARK: - Singleton

  public static let shared = SimulatorService()
  private init() {}

  /// Isolated instance for unit tests — production code uses `shared`.
  static func makeForTesting() -> SimulatorService {
    SimulatorService()
  }

  // MARK: - Observable State

  /// Per-UDID global boot/shutdown state, shared across all sessions
  private(set) var deviceStates: [String: SimulatorState] = [:]

  /// Per-(projectPath|UDID) build state — isolated per worktree session
  private(set) var sessionBuildStates: [String: SimulatorState] = [:]

  /// Per-(projectPath|hardware device ID) build state for physical iOS devices.
  private(set) var physicalRunStates: [String: SimulatorState] = [:]

  /// Cached list of runtimes with their available devices
  private(set) var runtimes: [SimulatorRuntime] = []

  /// Connected physical iOS/iPadOS run destinations.
  private(set) var physicalDevices: [PhysicalIOSDevice] = []

  /// True while the device list is being fetched
  private(set) var isLoadingDevices: Bool = false

  /// Per-projectPath macOS build-and-run state
  private(set) var macRunStates: [String: MacRunState] = [:]

  /// Per-projectPath preferred simulator UDID — shared across all views
  private(set) var preferredSimulatorUDIDs: [String: String] = [:]

  /// Per-projectPath preferred physical iOS device identifier.
  private(set) var preferredPhysicalDeviceIDs: [String: String] = [:]

  /// True once persisted preferences have been hydrated into the dictionaries.
  public private(set) var preferencesLoaded = false

  /// Backing store for run-destination preferences; nil until configured.
  private var preferenceStore: (any SimulatorPreferencePersisting)?

  /// In-flight hydration of persisted preferences.
  private var preferenceLoadTask: Task<Void, Never>?

  /// Serializes preference writes so they land in call order.
  private var preferencePersistChain: Task<Void, Never>?

  /// Live process references for in-flight Mac builds, keyed by projectPath
  private var macBuildProcesses: [String: ProcessRef] = [:]

  /// Live process references for in-flight simulator builds, keyed by projectPath|UDID
  private var simulatorBuildProcesses: [String: ProcessRef] = [:]

  /// Live process references for in-flight physical-device builds.
  private var physicalBuildProcesses: [String: ProcessRef] = [:]

  /// In-flight Phase 3 tasks for simulator builds, keyed by projectPath|UDID
  private var simulatorRunTasks: [String: Task<Result<Void, Error>, Never>] = [:]

  /// In-flight Phase 3 tasks for physical-device builds.
  private var physicalRunTasks: [String: Task<Result<Void, Error>, Never>] = [:]

  /// Cached workspace/project and scheme selection per project path.
  private var buildSetupCache: [String: BuildSetup] = [:]

  // MARK: - Public API

  /// Sets the preferred simulator UDID for a given project path.
  public func setPreferredSimulator(udid: String?, for projectPath: String) {
    preferredSimulatorUDIDs[projectPath] = udid
    persistPreference(for: projectPath)
  }

  /// Sets the preferred physical iOS device for a given project path.
  public func setPreferredPhysicalDevice(identifier: String?, for projectPath: String) {
    preferredPhysicalDeviceIDs[projectPath] = identifier
    persistPreference(for: projectPath)
  }

  /// Attaches the persistence backend and hydrates saved preferences.
  /// Persisted values never override selections already made this launch.
  public func configurePreferenceStore(_ store: any SimulatorPreferencePersisting) {
    preferenceStore = store
    preferenceLoadTask?.cancel()
    preferenceLoadTask = Task {
      let preferences = (try? await store.getProjectSimulatorPreferences()) ?? []
      guard !Task.isCancelled else { return }
      for preference in preferences {
        let path = preference.projectPath
        guard preferredSimulatorUDIDs[path] == nil, preferredPhysicalDeviceIDs[path] == nil else {
          continue
        }
        switch preference.kind {
        case .simulator:
          preferredSimulatorUDIDs[path] = preference.deviceIdentifier
        case .physical:
          preferredPhysicalDeviceIDs[path] = preference.deviceIdentifier
        }
      }
      preferencesLoaded = true
    }
  }

  /// Awaits preference hydration; returns immediately when no store is configured.
  public func ensurePreferencesLoaded() async {
    await preferenceLoadTask?.value
  }

  /// Awaits any queued preference writes (test hook).
  func flushPreferencePersistence() async {
    await preferencePersistChain?.value
  }

  private func persistPreference(for projectPath: String) {
    guard let store = preferenceStore else { return }
    let preference: ProjectSimulatorPreference?
    if let udid = preferredSimulatorUDIDs[projectPath] {
      preference = ProjectSimulatorPreference(
        projectPath: projectPath,
        deviceIdentifier: udid,
        kind: .simulator
      )
    } else if let identifier = preferredPhysicalDeviceIDs[projectPath] {
      preference = ProjectSimulatorPreference(
        projectPath: projectPath,
        deviceIdentifier: identifier,
        kind: .physical
      )
    } else {
      preference = nil
    }
    let previous = preferencePersistChain
    preferencePersistChain = Task {
      await previous?.value
      if let preference {
        try? await store.setProjectSimulatorPreference(preference)
      } else {
        try? await store.deleteProjectSimulatorPreference(projectPath: projectPath)
      }
    }
  }

  /// Returns the SimulatorDevice for a given UDID, if it exists in the loaded runtimes.
  func device(for udid: String) -> SimulatorDevice? {
    for runtime in runtimes {
      if let device = runtime.availableDevices.first(where: { $0.udid == udid }) {
        return device
      }
    }
    return nil
  }

  /// Whether the device is currently booted, consulting live boot state first
  /// (updated by boot/build flows) and falling back to the last device-list
  /// snapshot. Use this for UI gating rather than `SimulatorDevice.isBooted`,
  /// which only reflects the most recent `listDevices()`.
  public func isBooted(udid: String) -> Bool {
    if deviceStates[udid] == .booted { return true }
    return device(for: udid)?.isBooted == true
  }

  /// Returns the combined state for a device in a given session's context.
  /// Build state (building/failed) is per-session; boot state (booted/booting/shuttingDown) is global.
  public func state(for udid: String, projectPath: String) -> SimulatorState {
    let key = sessionKey(projectPath: projectPath, udid: udid)
    if let buildState = sessionBuildStates[key] {
      switch buildState {
      case .building, .installing, .launching, .failed: return buildState
      default: break
      }
    }
    return deviceStates[udid] ?? .idle
  }

  /// Returns the build/install/launch state for a physical iOS device.
  public func physicalDeviceState(for identifier: String, projectPath: String) -> SimulatorState {
    physicalRunStates[sessionKey(projectPath: projectPath, udid: identifier)] ?? .idle
  }

  /// Fetches simulator runtimes plus connected physical iOS devices.
  public func listDevices() async {
    guard !isLoadingDevices else { return }
    isLoadingDevices = true
    defer { isLoadingDevices = false }

    let simulatorTask = Task.detached {
      SimulatorService.fetchDeviceList()
    }
    let physicalDeviceTask = Task.detached {
      SimulatorService.fetchPhysicalDeviceList()
    }

    let result = await simulatorTask.value
    let physicalResult = await physicalDeviceTask.value

    switch result {
    case .success(let runtimes):
      self.runtimes = runtimes
      // Sync booted state into deviceStates for any devices already booted
      for runtime in runtimes {
        for device in runtime.availableDevices {
          if device.isBooted {
            if deviceStates[device.udid] == nil || deviceStates[device.udid] == .idle {
              deviceStates[device.udid] = .booted
            }
          } else if deviceStates[device.udid] == .booted {
            deviceStates[device.udid] = .idle
          }
        }
      }
      AppLogger.simulator.info("Loaded \(runtimes.count) runtimes")
    case .failure(let error):
      AppLogger.simulator.error("Failed to list devices: \(error.localizedDescription)")
    }

    switch physicalResult {
    case .success(let devices):
      physicalDevices = devices
      AppLogger.simulator.info("Loaded \(devices.count) physical iOS devices")
    case .failure(let error):
      AppLogger.simulator.error("Failed to list physical iOS devices: \(error.localizedDescription)")
    }
  }

  /// Boots a simulator device by UDID, then opens Simulator.app.
  ///
  /// Idempotent: if the device is already booted (`simctl boot` returns 149,
  /// "current state: Booted"), that's treated as success rather than a failure.
  public func bootDevice(udid: String) async {
    // Already booted (or a boot is already in flight) — nothing to do.
    if isBooted(udid: udid) {
      deviceStates[udid] = .booted
      return
    }
    deviceStates[udid] = .booting
    AppLogger.simulator.info("Booting device \(udid)")

    let exitCode = await Task.detached {
      SimulatorService.runSimctl(arguments: ["boot", udid])
    }.value

    // 149 = "Unable to boot device in current state: Booted" — already up.
    if exitCode == 0 || exitCode == 149 {
      deviceStates[udid] = .booted
      AppLogger.simulator.info("Device booted: \(udid)")
      await listDevices()
    } else {
      let msg = "xcrun simctl boot exited with code \(exitCode)"
      deviceStates[udid] = .failed(error: msg)
      AppLogger.simulator.error("\(msg)")
    }
  }

  /// Shuts down a simulator device by UDID.
  public func shutdownDevice(udid: String) async {
    deviceStates[udid] = .shuttingDown
    AppLogger.simulator.info("Shutting down device \(udid)")

    let exitCode = await Task.detached {
      SimulatorService.runSimctl(arguments: ["shutdown", udid])
    }.value

    deviceStates[udid] = .idle
    if exitCode != 0 {
      AppLogger.simulator.warning("xcrun simctl shutdown exited with code \(exitCode)")
    }
    await listDevices()
  }

  /// Brings Simulator.app to the foreground.
  public func openSimulatorApp() async {
    await Task.detached {
      SimulatorService.runOpenApp(name: "Simulator")
    }.value
  }

  /// Builds the project for macOS and opens the resulting app.
  /// Split into three phases so the live Process can be stored for cancellation.
  public func buildAndRunOnMac(projectPath: String) async {
    macRunStates[projectPath] = .building
    AppLogger.simulator.info("Building for Mac: \(projectPath)")

    // Phase 1: detect workspace/scheme off main actor (filesystem + one subprocess)
    let detectResult = await buildSetup(for: projectPath)

    guard case .success(let setup) = detectResult else {
      if case .failure(let e) = detectResult {
        macRunStates[projectPath] = .failed(error: e.localizedDescription)
        AppLogger.simulator.error("Mac build setup failed: \(e.localizedDescription)")
      }
      return
    }

    // Phase 2: configure process on main actor and store reference for cancellation
    let process = Process()
    process.executableURL = URL(fileURLWithPath: setup.xcodebuild)
    var buildArgs = [
      "build",
      "-quiet",
      "-scheme", setup.scheme,
      "-destination", "platform=macOS,arch=arm64",
      "-derivedDataPath", setup.derivedDataPath
    ]
    if setup.isWorkspace {
      buildArgs += ["-workspace", setup.targetPath]
    } else {
      buildArgs += ["-project", setup.targetPath]
    }
    process.arguments = buildArgs
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    let errorPipe = Pipe()
    process.standardError = errorPipe

    let ref = ProcessRef(process: process, outputPipe: outputPipe, errorPipe: errorPipe)
    macBuildProcesses[projectPath] = ref

    // Phase 3: execute off main actor
    let result = await Task.detached {
      SimulatorService.executeBuild(ref: ref, setup: setup)
    }.value

    macBuildProcesses.removeValue(forKey: projectPath)

    // Guard against a cancel() call that already set the state to .idle
    guard macRunStates[projectPath] == .building else { return }

    switch result {
    case .success(let appPath):
      macRunStates[projectPath] = .done
      AppLogger.simulator.info("Build succeeded, opening \(appPath)")
    case .failure(let error):
      macRunStates[projectPath] = .failed(error: error.localizedDescription)
      AppLogger.simulator.error("Mac build failed: \(error.localizedDescription)")
    }
  }

  /// Terminates an in-flight Mac build and resets state to idle.
  public func cancelBuild(projectPath: String) {
    macBuildProcesses[projectPath]?.process.terminate()
    macBuildProcesses.removeValue(forKey: projectPath)
    macRunStates[projectPath] = .idle
    AppLogger.simulator.info("Cancelled build for \(projectPath)")
  }

  /// Clears the cached workspace/project and scheme selection for a project.
  public func clearBuildCache(for projectPath: String) {
    buildSetupCache.removeValue(forKey: projectPath)
  }

  /// Builds for an iOS simulator, installs, and launches the app.
  ///
  /// When `hotReload` is provided (and effective), the build gets the
  /// injection engine's required settings (`-interposable`,
  /// `EMIT_FRONTEND_COMMAND_LINES`) and the launch inserts the support
  /// dylibs with stdout redirected to the plan's console log. Returns
  /// whether the full build–install–launch pipeline succeeded.
  /// `foregroundSimulatorApp` controls whether Simulator.app is brought to
  /// the front after launch. Panel-mirrored runs pass false — the in-app
  /// stream is the display, so the real window stays wherever it is (hidden).
  @discardableResult
  public func buildAndRunOnSimulator(
    udid: String,
    projectPath: String,
    hotReload: HotReloadLaunchPlan? = nil,
    foregroundSimulatorApp: Bool = true
  ) async -> Bool {
    let key = sessionKey(projectPath: projectPath, udid: udid)
    sessionBuildStates[key] = .building
    AppLogger.simulator.info("Building for simulator \(udid)")

    // Phase 1: detect workspace/scheme off main actor
    let detectResult = await buildSetup(for: projectPath)

    guard case .success(var setup) = detectResult else {
      if case .failure(let e) = detectResult {
        sessionBuildStates[key] = .failed(error: e.localizedDescription)
        AppLogger.simulator.error("Simulator build setup failed: \(e.localizedDescription)")
      }
      return false
    }

    // Injection-armed builds get their own derived data: the engine replays
    // per-file compile commands from the build log, which only exist for
    // files actually compiled with the hot-reload settings. A separate path
    // forces that full compile once (and keeps plain builds' cache intact);
    // it also guarantees the freshest .xcactivitylog is ours, so the engine
    // can't latch onto another project's log.
    if let hotReload, !hotReload.configuration.xcodebuildSettingOverrides.isEmpty {
      setup = setup.withDerivedDataPath(setup.derivedDataPath + "-hotreload")
    }

    // Phase 2: configure process on main actor and store for cancellation
    let process = Process()
    process.executableURL = URL(fileURLWithPath: setup.xcodebuild)
    let isInjectionArmed =
      hotReload.map { !$0.configuration.xcodebuildSettingOverrides.isEmpty } ?? false
    var buildArgs = ["build"]
    if !isInjectionArmed {
      // Armed builds need the full transcript: EMIT_FRONTEND_COMMAND_LINES
      // puts the per-file swift-frontend commands on stdout, and the
      // synthetic activity log is built from them (Xcode 26 CLI builds
      // persist only empty logs).
      buildArgs.append("-quiet")
    }
    buildArgs += [
      "-scheme", setup.scheme,
      "-destination", "generic/platform=iOS Simulator",
      "-derivedDataPath", setup.derivedDataPath
    ]
    if setup.isWorkspace {
      buildArgs += ["-workspace", setup.targetPath]
    } else {
      buildArgs += ["-project", setup.targetPath]
    }
    if let hotReload {
      buildArgs += hotReload.configuration.xcodebuildSettingOverrides
    }
    process.arguments = buildArgs
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    let errorPipe = Pipe()
    process.standardError = errorPipe

    let ref = ProcessRef(process: process, outputPipe: outputPipe, errorPipe: errorPipe)
    simulatorBuildProcesses[key] = ref

    // Phase 3: execute off main actor; store the task so cancelSimulatorBuild can cancel it
    let phase3Task = Task.detached {
      await SimulatorService.executeSimulatorBuild(
        ref: ref, udid: udid, sessionKey: key, setup: setup, hotReload: hotReload,
        foregroundSimulatorApp: foregroundSimulatorApp)
    }
    simulatorRunTasks[key] = phase3Task
    let result = await phase3Task.value
    simulatorRunTasks.removeValue(forKey: key)

    simulatorBuildProcesses.removeValue(forKey: key)

    // Guard against a cancel() call that already removed the key from sessionBuildStates.
    // We can't check for .building here because installAndLaunch mutates the state to
    // .installing / .launching while Phase 3 is still in flight.
    guard sessionBuildStates[key] != nil else { return false }

    switch result {
    case .success:
      sessionBuildStates.removeValue(forKey: key)
      deviceStates[udid] = .booted
      AppLogger.simulator.info("Simulator build+run succeeded for \(udid)")
      return true
    case .failure(let error):
      sessionBuildStates[key] = .failed(error: error.localizedDescription)
      AppLogger.simulator.error("Simulator build failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Builds for a connected physical iOS/iPadOS device, installs, and launches the app.
  @discardableResult
  public func buildAndRunOnPhysicalDevice(
    identifier: String,
    projectPath: String
  ) async -> Bool {
    let key = sessionKey(projectPath: projectPath, udid: identifier)
    physicalRunStates[key] = .building
    AppLogger.simulator.info("Building for physical iOS device \(identifier)")

    let detectResult = await buildSetup(for: projectPath)

    guard case .success(let setup) = detectResult else {
      if case .failure(let e) = detectResult {
        physicalRunStates[key] = .failed(error: e.localizedDescription)
        AppLogger.simulator.error("Physical device build setup failed: \(e.localizedDescription)")
      }
      return false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: setup.xcodebuild)
    let buildArgs = SimulatorService.physicalDeviceBuildArguments(
      scheme: setup.scheme,
      targetPath: setup.targetPath,
      isWorkspace: setup.isWorkspace,
      identifier: identifier,
      derivedDataPath: setup.derivedDataPath
    )
    process.arguments = buildArgs
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    let errorPipe = Pipe()
    process.standardError = errorPipe

    let ref = ProcessRef(process: process, outputPipe: outputPipe, errorPipe: errorPipe)
    physicalBuildProcesses[key] = ref

    let phase3Task = Task.detached {
      await SimulatorService.executePhysicalDeviceBuild(
        ref: ref,
        deviceIdentifier: identifier,
        sessionKey: key,
        setup: setup
      )
    }
    physicalRunTasks[key] = phase3Task
    let result = await phase3Task.value
    physicalRunTasks.removeValue(forKey: key)
    physicalBuildProcesses.removeValue(forKey: key)

    guard physicalRunStates[key] != nil else { return false }

    switch result {
    case .success:
      physicalRunStates[key] = .booted
      AppLogger.simulator.info("Physical device build+run succeeded for \(identifier)")
      return true
    case .failure(let error):
      physicalRunStates[key] = .failed(error: error.localizedDescription)
      AppLogger.simulator.error("Physical device build failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Relaunches the project's already-installed app with the hot-reload
  /// dylibs inserted — no rebuild, ~1s. Used by the Previews tab to
  /// self-heal when the running app was launched without the preview host
  /// (dylibs can only be inserted at launch). Returns false when no built
  /// app can be resolved (a full Build & Run is needed) or launch fails.
  public func relaunchWithHotReload(
    udid: String,
    projectPath: String,
    hotReload: HotReloadLaunchPlan
  ) async -> Bool {
    let key = sessionKey(projectPath: projectPath, udid: udid)
    guard case .success(let setup) = await buildSetup(for: projectPath) else {
      return false
    }
    sessionBuildStates[key] = .launching
    let success = await Task.detached {
      SimulatorService.launchExistingApp(
        udid: udid, setup: setup, hotReload: hotReload)
    }.value
    sessionBuildStates.removeValue(forKey: key)
    if success {
      deviceStates[udid] = .booted
      AppLogger.simulator.info("Relaunched app with hot reload for \(udid)")
    }
    return success
  }

  /// Finds the most recent built app (armed derived data first, then plain)
  /// and relaunches it by bundle identifier with the plan's environment.
  private nonisolated static func launchExistingApp(
    udid: String,
    setup: BuildSetup,
    hotReload: HotReloadLaunchPlan
  ) -> Bool {
    var bundle: String?
    for derivedDataPath in [setup.derivedDataPath + "-hotreload", setup.derivedDataPath] {
      if let app = resolveBuiltApp(
        derivedDataPath: derivedDataPath,
        scheme: setup.scheme,
        platform: .iOSSimulator,
        requiresBundleIdentifier: true
      ), let identifier = app.bundleIdentifier {
        bundle = identifier
        break
      }
    }
    guard let bundle else { return false }

    var launchArguments = ["launch"]
    var launchEnvironment: [String: String]?
    if hotReload.configuration.isEffective {
      launchArguments += hotReload.configuration.launchArguments(
        consoleStdoutPath: hotReload.consoleStdoutPath)
      launchEnvironment = hotReload.configuration.simctlChildEnvironment()
    }
    launchArguments += [udid, bundle]
    return runSimctl(arguments: launchArguments, environment: launchEnvironment) == 0
  }

  /// Terminates an in-flight simulator build and clears this session's build state.
  public func cancelSimulatorBuild(udid: String, projectPath: String) {
    let key = sessionKey(projectPath: projectPath, udid: udid)
    simulatorBuildProcesses[key]?.process.terminate()
    simulatorBuildProcesses.removeValue(forKey: key)
    simulatorRunTasks[key]?.cancel()
    simulatorRunTasks.removeValue(forKey: key)
    sessionBuildStates.removeValue(forKey: key)
    AppLogger.simulator.info("Cancelled simulator build for \(udid)")
  }

  /// Terminates an in-flight physical-device build and clears this session's run state.
  public func cancelPhysicalDeviceRun(identifier: String, projectPath: String) {
    let key = sessionKey(projectPath: projectPath, udid: identifier)
    physicalBuildProcesses[key]?.process.terminate()
    physicalBuildProcesses.removeValue(forKey: key)
    physicalRunTasks[key]?.cancel()
    physicalRunTasks.removeValue(forKey: key)
    physicalRunStates.removeValue(forKey: key)
    AppLogger.simulator.info("Cancelled physical device build for \(identifier)")
  }

  // MARK: - Key Helpers

  private func sessionKey(projectPath: String, udid: String) -> String {
    "\(projectPath)|\(udid)"
  }

  private func buildSetup(for projectPath: String) async -> Result<BuildSetup, Error> {
    if let cached = buildSetupCache[projectPath] {
      AppLogger.simulator.info("Using cached build setup for \(projectPath, privacy: .public)")
      return .success(cached)
    }

    let start = SimulatorService.phaseTimestamp()
    let detectResult = await Task.detached {
      SimulatorService.detectBuildTarget(projectPath: projectPath)
    }.value

    if case .success(let setup) = detectResult {
      buildSetupCache[projectPath] = setup
      let duration = SimulatorService.formattedElapsed(since: start)
      AppLogger.simulator.info(
        "Detected build setup for scheme \(setup.scheme, privacy: .public) in \(duration, privacy: .public)s"
      )
    } else if case .failure(let error) = detectResult {
      let duration = SimulatorService.formattedElapsed(since: start)
      AppLogger.simulator.error(
        "Build setup detection failed in \(duration, privacy: .public)s: \(error.localizedDescription, privacy: .public)"
      )
    }

    return detectResult
  }

  // MARK: - Process Helpers (nonisolated)

  /// Waits for a simulator to fully boot, terminating the process after `timeout` seconds.
  private nonisolated static func waitForBootReady(udid: String, timeout: TimeInterval = 90) -> Bool {
    guard let xcrun = findExecutable(named: "xcrun") else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = ["simctl", "bootstatus", udid, "-b"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return false }

    let timeoutItem = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    process.waitUntilExit()
    timeoutItem.cancel()

    return process.terminationStatus == 0
  }

  /// Runs `xcrun simctl <arguments>` and returns the exit code.
  /// `environment` entries are merged over the inherited environment
  /// (simctl forwards `SIMCTL_CHILD_`-prefixed variables to launched apps).
  private nonisolated static func runSimctl(
    arguments: [String],
    environment: [String: String]? = nil
  ) -> Int32 {
    guard let xcrun = findExecutable(named: "xcrun") else {
      AppLogger.simulator.error("xcrun not found in PATH")
      return -1
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = ["simctl"] + arguments
    if let environment, !environment.isEmpty {
      process.environment = ProcessInfo.processInfo.environment
        .merging(environment) { _, override in override }
    }
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    } catch {
      AppLogger.simulator.error("Failed to run xcrun simctl: \(error.localizedDescription)")
      return -1
    }
  }

  /// Runs `xcrun devicectl <arguments>` and captures output for diagnostics.
  private nonisolated static func runDeviceCtl(arguments: [String]) -> ProcessExecutionResult {
    guard let xcrun = findExecutable(named: "xcrun") else {
      AppLogger.simulator.error("xcrun not found in PATH")
      return ProcessExecutionResult(
        exitCode: -1,
        outputText: "",
        errorText: "xcrun not found"
      )
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = ["devicectl"] + arguments
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    let errorPipe = Pipe()
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      AppLogger.simulator.error("Failed to run xcrun devicectl: \(error.localizedDescription)")
      return ProcessExecutionResult(
        exitCode: -1,
        outputText: "",
        errorText: error.localizedDescription
      )
    }

    return ProcessExecutionResult(
      exitCode: process.terminationStatus,
      outputText: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      errorText: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  /// Runs `open -a <name>` to bring an app to the foreground.
  private nonisolated static func runOpenApp(name: String) {
    guard let open = findExecutable(named: "open") else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: open)
    process.arguments = ["-a", name]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
  }

  /// Opens an app at the given path.
  private nonisolated static func runOpenPath(_ path: String) {
    guard let open = findExecutable(named: "open") else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: open)
    process.arguments = [path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
  }

  /// Phase 1: finds workspace/project, scheme, and xcodebuild path.
  private nonisolated static func detectBuildTarget(projectPath: String) -> Result<BuildSetup, Error> {
    guard let target = detectWorkspaceOrProject(at: projectPath) else {
      return .failure(NSError(domain: "SimulatorService", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "No Xcode project or workspace found"]))
    }
    guard let xcodebuild = findExecutable(named: "xcodebuild") else {
      return .failure(NSError(domain: "SimulatorService", code: -5,
        userInfo: [NSLocalizedDescriptionKey: "xcodebuild not found"]))
    }
    guard let scheme = detectScheme(for: target, xcodebuild: xcodebuild) else {
      return .failure(NSError(domain: "SimulatorService", code: -4,
        userInfo: [NSLocalizedDescriptionKey: "No scheme found in project"]))
    }
    let derivedDataPath = derivedDataPath(for: projectPath)
    do {
      try ensureDirectoryExists(atPath: derivedDataPath)
    } catch {
      return .failure(error)
    }
    return .success(BuildSetup(
      targetPath: target.path,
      isWorkspace: target.isWorkspace,
      scheme: scheme,
      xcodebuild: xcodebuild,
      derivedDataPath: derivedDataPath
    ))
  }

  /// Extracts a human-readable error from xcodebuild output.
  /// xcodebuild writes compiler errors (`: error: `) to stdout; the stderr summary only has
  /// `** BUILD FAILED ** (N failures)` which is not helpful on its own.
  private nonisolated static func extractBuildError(
    outputText: String,
    stderrText: String,
    exitCode: Int32
  ) -> String {
    let errors = outputText
      .components(separatedBy: "\n")
      .filter { $0.contains(": error: ") }
      .compactMap { line -> String? in
        guard let range = line.range(of: ": error: ") else { return nil }
        return String(line[range.upperBound...])
      }
    if !errors.isEmpty {
      return errors.joined(separator: "\n")
    }
    return stderrText
      .components(separatedBy: "\n")
      .filter { !$0.isEmpty }
      .last ?? "Build failed (exit \(exitCode))"
  }

  private nonisolated static func devicectlFailureMessage(
    prefix: String,
    result: ProcessExecutionResult
  ) -> String {
    let details = [result.errorText, result.outputText]
      .flatMap { $0.components(separatedBy: "\n") }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard let lastDetail = details.last else {
      return "\(prefix) (exit \(result.exitCode))"
    }
    return "\(prefix): \(lastDetail)"
  }

  /// Phase 3: runs the already-configured process, waits for it, finds and opens the app.
  private nonisolated static func executeBuild(
    ref: ProcessRef,
    setup: BuildSetup
  ) -> Result<String, Error> {
    let stdoutChunks = BuildOutputAccumulator()
    let stderrChunks = BuildOutputAccumulator()
    ref.outputPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      stdoutChunks.append(chunk)
    }
    ref.errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      stderrChunks.append(chunk)
    }
    do {
      try ref.process.run()
      ref.process.waitUntilExit()
    } catch {
      ref.outputPipe.fileHandleForReading.readabilityHandler = nil
      ref.errorPipe.fileHandleForReading.readabilityHandler = nil
      return .failure(error)
    }
    ref.outputPipe.fileHandleForReading.readabilityHandler = nil
    ref.errorPipe.fileHandleForReading.readabilityHandler = nil
    let tail = ref.outputPipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { stdoutChunks.append(tail) }
    let errorTail = ref.errorPipe.fileHandleForReading.readDataToEndOfFile()
    if !errorTail.isEmpty { stderrChunks.append(errorTail) }

    guard ref.process.terminationStatus == 0 else {
      // Terminated by signal means the user cancelled — return a benign error
      if ref.process.terminationReason == .uncaughtSignal {
        return .failure(NSError(domain: "SimulatorService", code: -7,
          userInfo: [NSLocalizedDescriptionKey: "Build cancelled"]))
      }
      let outputText = String(data: stdoutChunks.combinedData(), encoding: .utf8) ?? ""
      let stderrText = String(data: stderrChunks.combinedData(), encoding: .utf8) ?? ""
      let msg = SimulatorService.extractBuildError(outputText: outputText, stderrText: stderrText, exitCode: ref.process.terminationStatus)
      return .failure(NSError(domain: "SimulatorService",
        code: Int(ref.process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: msg]))
    }

    guard let builtApp = resolveBuiltApp(
      derivedDataPath: setup.derivedDataPath,
      scheme: setup.scheme,
      platform: .macOS,
      requiresBundleIdentifier: false
    ) else {
      return .failure(NSError(domain: "SimulatorService", code: -6,
        userInfo: [NSLocalizedDescriptionKey: "Could not locate built app"]))
    }

    runOpenPath(builtApp.appPath)
    return .success(builtApp.appPath)
  }

  /// Runs xcodebuild for the given simulator UDID, then installs and launches the app.
  private nonisolated static func executeSimulatorBuild(
    ref: ProcessRef,
    udid: String,
    sessionKey: String,
    setup: BuildSetup,
    hotReload: HotReloadLaunchPlan? = nil,
    foregroundSimulatorApp: Bool = true
  ) async -> Result<Void, Error> {
    let totalStart = phaseTimestamp()
    let bootTask = Task.detached(priority: .utility) {
      SimulatorService.runSimctl(arguments: ["boot", udid])
    }

    let buildStart = phaseTimestamp()
    let stdoutChunks = BuildOutputAccumulator()
    let stderrChunks = BuildOutputAccumulator()
    ref.outputPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      stdoutChunks.append(chunk)
    }
    ref.errorPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      stderrChunks.append(chunk)
    }
    do {
      try ref.process.run()
      ref.process.waitUntilExit()
    } catch {
      ref.outputPipe.fileHandleForReading.readabilityHandler = nil
      ref.errorPipe.fileHandleForReading.readabilityHandler = nil
      return .failure(error)
    }
    ref.outputPipe.fileHandleForReading.readabilityHandler = nil
    ref.errorPipe.fileHandleForReading.readabilityHandler = nil
    let tail = ref.outputPipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { stdoutChunks.append(tail) }
    let errorTail = ref.errorPipe.fileHandleForReading.readDataToEndOfFile()
    if !errorTail.isEmpty { stderrChunks.append(errorTail) }

    guard ref.process.terminationStatus == 0 else {
      if ref.process.terminationReason == .uncaughtSignal {
        return .failure(NSError(domain: "SimulatorService", code: -7,
          userInfo: [NSLocalizedDescriptionKey: "Build cancelled"]))
      }
      let outputText = String(data: stdoutChunks.combinedData(), encoding: .utf8) ?? ""
      let stderrText = String(data: stderrChunks.combinedData(), encoding: .utf8) ?? ""
      let msg = SimulatorService.extractBuildError(outputText: outputText, stderrText: stderrText, exitCode: ref.process.terminationStatus)
      return .failure(NSError(domain: "SimulatorService",
        code: Int(ref.process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: msg]))
    }

    AppLogger.simulator.info(
      "xcodebuild finished for scheme \(setup.scheme, privacy: .public) in \(formattedElapsed(since: buildStart), privacy: .public)s"
    )

    // Persist the per-file compile commands where the injection engine looks
    // for them, before the app launches (its log discovery replays recent
    // file events at boot).
    if let hotReload, !hotReload.configuration.xcodebuildSettingOverrides.isEmpty {
      do {
        if let logURL = try HotReloadBuildLogSynthesizer.writeSyntheticLog(
          buildOutput: stdoutChunks.combinedData(),
          derivedDataPath: setup.derivedDataPath
        ) {
          AppLogger.simulator.info(
            "Wrote synthetic build log \(logURL.lastPathComponent, privacy: .public)")
        }
      } catch {
        AppLogger.simulator.error(
          "Synthetic build log failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    let bootExitCode = await bootTask.value
    if bootExitCode != 0 {
      AppLogger.simulator.info(
        "simctl boot exited with code \(bootExitCode) for \(udid, privacy: .private(mask: .hash)); continuing to bootstatus"
      )
    }

    let bootReadyStart = phaseTimestamp()
    guard waitForBootReady(udid: udid) else {
      return .failure(NSError(domain: "SimulatorService", code: -10,
        userInfo: [NSLocalizedDescriptionKey: "Simulator did not become ready within 90 seconds"]))
    }
    AppLogger.simulator.info(
      "Simulator became ready in \(formattedElapsed(since: bootReadyStart), privacy: .public)s"
    )

    let result = await installAndLaunch(
      udid: udid,
      sessionKey: sessionKey,
      setup: setup,
      hotReload: hotReload,
      foregroundSimulatorApp: foregroundSimulatorApp
    )

    if case .success = result {
      AppLogger.simulator.info(
        "Simulator run completed in \(formattedElapsed(since: totalStart), privacy: .public)s for scheme \(setup.scheme, privacy: .public)"
      )
    }

    return result
  }

  /// Runs xcodebuild for a physical iOS device, then installs and launches the app.
  private nonisolated static func executePhysicalDeviceBuild(
    ref: ProcessRef,
    deviceIdentifier: String,
    sessionKey: String,
    setup: BuildSetup
  ) async -> Result<Void, Error> {
    let totalStart = phaseTimestamp()
    let buildStart = phaseTimestamp()
    let stdoutChunks = DataAccumulator()
    ref.outputPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      stdoutChunks.append(chunk)
    }
    do {
      try ref.process.run()
      ref.process.waitUntilExit()
    } catch {
      ref.outputPipe.fileHandleForReading.readabilityHandler = nil
      return .failure(error)
    }
    ref.outputPipe.fileHandleForReading.readabilityHandler = nil
    let tail = ref.outputPipe.fileHandleForReading.readDataToEndOfFile()
    if !tail.isEmpty { stdoutChunks.append(tail) }

    guard ref.process.terminationStatus == 0 else {
      if ref.process.terminationReason == .uncaughtSignal {
        return .failure(NSError(domain: "SimulatorService", code: -7,
          userInfo: [NSLocalizedDescriptionKey: "Build cancelled"]))
      }
      let outputText = String(data: stdoutChunks.combinedData(), encoding: .utf8) ?? ""
      let stderrText = String(data: ref.errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let msg = SimulatorService.extractBuildError(outputText: outputText, stderrText: stderrText, exitCode: ref.process.terminationStatus)
      return .failure(NSError(domain: "SimulatorService",
        code: Int(ref.process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: msg]))
    }

    AppLogger.simulator.info(
      "xcodebuild finished for physical device scheme \(setup.scheme, privacy: .public) in \(formattedElapsed(since: buildStart), privacy: .public)s"
    )

    let result = await installAndLaunchPhysicalDevice(
      identifier: deviceIdentifier,
      sessionKey: sessionKey,
      setup: setup
    )

    if case .success = result {
      AppLogger.simulator.info(
        "Physical device run completed in \(formattedElapsed(since: totalStart), privacy: .public)s for scheme \(setup.scheme, privacy: .public)"
      )
    }

    return result
  }

  /// Locates the built simulator app, installs it, and launches it.
  private nonisolated static func installAndLaunch(
    udid: String,
    sessionKey: String,
    setup: BuildSetup,
    hotReload: HotReloadLaunchPlan? = nil,
    foregroundSimulatorApp: Bool = true
  ) async -> Result<Void, Error> {
    guard findExecutable(named: "xcrun") != nil else {
      return .failure(NSError(domain: "SimulatorService", code: -8,
        userInfo: [NSLocalizedDescriptionKey: "xcrun not found"]))
    }

    guard let builtApp = resolveBuiltApp(
      derivedDataPath: setup.derivedDataPath,
      scheme: setup.scheme,
      platform: .iOSSimulator,
      requiresBundleIdentifier: true
    ),
    let bundle = builtApp.bundleIdentifier else {
      return .failure(NSError(domain: "SimulatorService", code: -9,
        userInfo: [NSLocalizedDescriptionKey: "Could not locate built simulator app"]))
    }

    AppLogger.simulator.info(
      "Resolved built app at \(builtApp.appPath, privacy: .public) with bundle \(bundle, privacy: .public)"
    )

    await MainActor.run {
      SimulatorService.shared.sessionBuildStates[sessionKey] = .installing
    }

    // Install
    let installStart = phaseTimestamp()
    let installCode = runSimctl(arguments: ["install", udid, builtApp.appPath])
    guard installCode == 0 else {
      return .failure(NSError(domain: "SimulatorService", code: Int(installCode),
        userInfo: [NSLocalizedDescriptionKey: "simctl install failed (exit \(installCode))"]))
    }
    AppLogger.simulator.info(
      "Installed app on simulator in \(formattedElapsed(since: installStart), privacy: .public)s"
    )

    await MainActor.run {
      SimulatorService.shared.sessionBuildStates[sessionKey] = .launching
    }

    // Launch — hot-reload launches insert the support dylibs (passed to the
    // app via simctl's SIMCTL_CHILD_ environment forwarding), terminate any
    // running copy, and redirect stdout to the tailed console log.
    let launchStart = phaseTimestamp()
    var launchArguments = ["launch"]
    var launchEnvironment: [String: String]?
    if let hotReload, hotReload.configuration.isEffective {
      launchArguments += hotReload.configuration.launchArguments(
        consoleStdoutPath: hotReload.consoleStdoutPath)
      launchEnvironment = hotReload.configuration.simctlChildEnvironment()
    }
    launchArguments += [udid, bundle]
    let launchCode = runSimctl(
      arguments: launchArguments, environment: launchEnvironment)
    guard launchCode == 0 else {
      return .failure(NSError(domain: "SimulatorService", code: Int(launchCode),
        userInfo: [NSLocalizedDescriptionKey: "simctl launch failed (exit \(launchCode))"]))
    }
    AppLogger.simulator.info(
      "Launched app in \(formattedElapsed(since: launchStart), privacy: .public)s"
    )

    // Bring Simulator.app to the foreground — skipped for panel-mirrored
    // runs, where the in-app stream is the display and the real window
    // stays hidden.
    if foregroundSimulatorApp {
      runOpenApp(name: "Simulator")
    }
    return .success(())
  }

  /// Locates the built device app, installs it with devicectl, and launches it.
  private nonisolated static func installAndLaunchPhysicalDevice(
    identifier: String,
    sessionKey: String,
    setup: BuildSetup
  ) async -> Result<Void, Error> {
    guard let builtApp = resolveBuiltApp(
      derivedDataPath: setup.derivedDataPath,
      scheme: setup.scheme,
      platform: .iOSDevice,
      requiresBundleIdentifier: true
    ),
    let bundle = builtApp.bundleIdentifier else {
      return .failure(NSError(domain: "SimulatorService", code: -11,
        userInfo: [NSLocalizedDescriptionKey: "Could not locate built device app"]))
    }

    AppLogger.simulator.info(
      "Resolved physical device app at \(builtApp.appPath, privacy: .public) with bundle \(bundle, privacy: .public)"
    )

    await MainActor.run {
      SimulatorService.shared.physicalRunStates[sessionKey] = .installing
    }

    let installStart = phaseTimestamp()
    let installResult = runDeviceCtl(arguments: [
      "device", "install", "app",
      "--device", identifier,
      builtApp.appPath
    ])
    guard installResult.exitCode == 0 else {
      return .failure(NSError(domain: "SimulatorService", code: Int(installResult.exitCode),
        userInfo: [
          NSLocalizedDescriptionKey: devicectlFailureMessage(
            prefix: "devicectl install failed",
            result: installResult
          )
        ]))
    }
    AppLogger.simulator.info(
      "Installed app on physical device in \(formattedElapsed(since: installStart), privacy: .public)s"
    )

    await MainActor.run {
      SimulatorService.shared.physicalRunStates[sessionKey] = .launching
    }

    let launchStart = phaseTimestamp()
    let launchResult = runDeviceCtl(arguments: [
      "device", "process", "launch",
      "--device", identifier,
      "--terminate-existing",
      bundle
    ])
    guard launchResult.exitCode == 0 else {
      return .failure(NSError(domain: "SimulatorService", code: Int(launchResult.exitCode),
        userInfo: [
          NSLocalizedDescriptionKey: devicectlFailureMessage(
            prefix: "devicectl launch failed",
            result: launchResult
          )
        ]))
    }
    AppLogger.simulator.info(
      "Launched app on physical device in \(formattedElapsed(since: launchStart), privacy: .public)s"
    )

    return .success(())
  }

  /// Finds a .xcworkspace (not inside .xcodeproj) or .xcodeproj at root or one subdir deep.
  private nonisolated static func detectWorkspaceOrProject(
    at path: String
  ) -> (path: String, isWorkspace: Bool)? {
    let fm = FileManager.default

    func standaloneWorkspace(in dir: String) -> String? {
      guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
      guard let name = items.first(where: {
        $0.hasSuffix(".xcworkspace") && !$0.hasPrefix(".")
      }) else { return nil }
      return (dir as NSString).appendingPathComponent(name)
    }

    func xcodeproj(in dir: String) -> String? {
      guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
      guard let name = items.first(where: { $0.hasSuffix(".xcodeproj") }) else { return nil }
      return (dir as NSString).appendingPathComponent(name)
    }

    // Root-level workspace
    if let ws = standaloneWorkspace(in: path) { return (ws, true) }

    // One subdir deep
    if let subdirs = try? fm.contentsOfDirectory(atPath: path) {
      for sub in subdirs {
        var isDir: ObjCBool = false
        let full = (path as NSString).appendingPathComponent(sub)
        fm.fileExists(atPath: full, isDirectory: &isDir)
        guard isDir.boolValue, !sub.hasSuffix(".xcodeproj"), !sub.hasSuffix(".xcworkspace") else {
          continue
        }
        if let ws = standaloneWorkspace(in: full) { return (ws, true) }
      }
    }

    // Fall back to .xcodeproj
    if let proj = xcodeproj(in: path) { return (proj, false) }
    if let subdirs = try? fm.contentsOfDirectory(atPath: path) {
      for sub in subdirs {
        var isDir: ObjCBool = false
        let full = (path as NSString).appendingPathComponent(sub)
        fm.fileExists(atPath: full, isDirectory: &isDir)
        if isDir.boolValue, let proj = xcodeproj(in: full) { return (proj, false) }
      }
    }
    return nil
  }

  /// Runs `xcodebuild -list -json` and picks the first non-test scheme.
  private nonisolated static func detectScheme(
    for target: (path: String, isWorkspace: Bool),
    xcodebuild: String
  ) -> String? {
    var args = ["-list", "-json"]
    if target.isWorkspace {
      args += ["-workspace", target.path]
    } else {
      args += ["-project", target.path]
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcodebuild)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }

    let schemes: [String]
    if let workspace = json["workspace"] as? [String: Any],
       let s = workspace["schemes"] as? [String] {
      schemes = s
    } else if let project = json["project"] as? [String: Any],
              let s = project["schemes"] as? [String] {
      schemes = s
    } else {
      return nil
    }

    return schemes.first(where: { !$0.lowercased().contains("test") }) ?? schemes.first
  }

  nonisolated static func derivedDataPath(for projectPath: String) -> String {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    let buildsDirectory = appSupport
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("Builds", isDirectory: true)
    let digest = SHA256.hash(data: Data(projectPath.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return buildsDirectory.appendingPathComponent(digest, isDirectory: true).path
  }

  nonisolated static func physicalDeviceBuildArguments(
    scheme: String,
    targetPath: String,
    isWorkspace: Bool,
    identifier: String,
    derivedDataPath: String
  ) -> [String] {
    var arguments = [
      "build",
      "-quiet",
      "-scheme", scheme,
      "-destination", "id=\(identifier)",
      "-destination-timeout", "30",
      "-derivedDataPath", derivedDataPath,
      "-allowProvisioningUpdates",
      "-allowProvisioningDeviceRegistration"
    ]
    if isWorkspace {
      arguments += ["-workspace", targetPath]
    } else {
      arguments += ["-project", targetPath]
    }
    return arguments
  }

  nonisolated static func preferredAppBundlePath(
    in productsDirectory: String,
    preferredAppName: String
  ) -> String? {
    preferredAppBundlePaths(
      in: productsDirectory,
      preferredAppName: preferredAppName,
      platform: nil
    ).first
  }

  nonisolated static func preferredAppBundlePaths(
    in productsDirectory: String,
    preferredAppName: String,
    platform: BuildPlatform?
  ) -> [String] {
    struct Candidate {
      let url: URL
      let nameScore: Int
      let platformScore: Int
      let modified: Date
    }

    let rootURL = URL(fileURLWithPath: productsDirectory, isDirectory: true)
      .standardizedFileURL
    let fileManager = FileManager.default
    guard let candidates = try? FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }

    var searchURLs = candidates
    if let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      while let item = enumerator.nextObject() as? URL {
        searchURLs.append(item)
        if item.pathExtension == "app" {
          enumerator.skipDescendants()
        }
      }
    }

    let preferredBundleName = "\(preferredAppName).app".lowercased()

    func relativeComponents(for url: URL) -> [String] {
      let parentURL = url.deletingLastPathComponent().standardizedFileURL
      let rootComponents = rootURL.pathComponents
      let parentComponents = parentURL.pathComponents
      guard parentComponents.count >= rootComponents.count else { return [] }
      return Array(parentComponents.dropFirst(rootComponents.count))
    }

    func scoreName(for url: URL) -> Int {
      let name = url.lastPathComponent.lowercased()
      var score = 0

      if name == preferredBundleName {
        score += 100
      } else if name.contains(preferredAppName.lowercased()) {
        score += 25
      }

      if name.contains("tests-runner") || name.contains("uitests-runner") {
        score -= 100
      }

      return score
    }

    let apps = searchURLs.compactMap { url -> Candidate? in
      guard url.pathExtension == "app" else { return nil }
      let platformScore: Int
      if let platform {
        guard let score = platform.scoreProductPathComponents(relativeComponents(for: url)) else {
          return nil
        }
        platformScore = score
      } else {
        platformScore = 0
      }

      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return Candidate(
        url: url.standardizedFileURL,
        nameScore: scoreName(for: url),
        platformScore: platformScore,
        modified: modified
      )
    }

    return apps.sorted { lhs, rhs in
      if lhs.nameScore != rhs.nameScore {
        return lhs.nameScore > rhs.nameScore
      }
      if lhs.platformScore != rhs.platformScore {
        return lhs.platformScore > rhs.platformScore
      }
      return lhs.modified > rhs.modified
    }
    .map(\.url.path)
  }

  nonisolated static func bundleIdentifier(atAppPath appPath: String) -> String? {
    let infoPlistPath = (appPath as NSString).appendingPathComponent("Info.plist")
    guard let plist = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any] else {
      return nil
    }
    return plist["CFBundleIdentifier"] as? String
  }

  nonisolated static func resolveBuiltApp(
    derivedDataPath: String,
    scheme: String,
    platform: BuildPlatform,
    requiresBundleIdentifier: Bool
  ) -> BuiltAppInfo? {
    let productsDirectory = (derivedDataPath as NSString)
      .appendingPathComponent("Build/Products")
    let candidatePaths = preferredAppBundlePaths(
      in: productsDirectory,
      preferredAppName: scheme,
      platform: platform
    )
    for appPath in candidatePaths {
      let bundleIdentifier = requiresBundleIdentifier ? bundleIdentifier(atAppPath: appPath) : nil
      if requiresBundleIdentifier && bundleIdentifier == nil {
        continue
      }
      return BuiltAppInfo(appPath: appPath, bundleIdentifier: bundleIdentifier)
    }

    return nil
  }

  private nonisolated static func ensureDirectoryExists(atPath path: String) throws {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path, isDirectory: true),
      withIntermediateDirectories: true
    )
  }

  private nonisolated static func phaseTimestamp() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  private nonisolated static func formattedElapsed(since start: TimeInterval) -> String {
    let elapsed = max(0, ProcessInfo.processInfo.systemUptime - start)
    return String(format: "%.2f", elapsed)
  }

  /// Parses `xcrun simctl list devices --json` and returns iOS runtimes sorted newest-first.
  private nonisolated static func fetchDeviceList() -> Result<[SimulatorRuntime], Error> {
    guard let xcrun = findExecutable(named: "xcrun") else {
      return .failure(NSError(domain: "SimulatorService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "xcrun not found"]))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = ["simctl", "list", "devices", "--json"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return .failure(error)
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    do {
      let runtimes = try parseDeviceList(from: data)
      return .success(runtimes)
    } catch {
      return .failure(error)
    }
  }

  /// Lists connected physical iOS devices, preferring CoreDevice's stable JSON output.
  private nonisolated static func fetchPhysicalDeviceList() -> Result<[PhysicalIOSDevice], Error> {
    let devicectlResult = fetchPhysicalDeviceListFromDeviceCtl()
    if case .success = devicectlResult {
      return devicectlResult
    }
    return fetchPhysicalDeviceListFromXCDevice()
  }

  /// Parses `xcrun devicectl list devices --json-output` and returns connected physical iOS devices.
  private nonisolated static func fetchPhysicalDeviceListFromDeviceCtl() -> Result<[PhysicalIOSDevice], Error> {
    guard let xcrun = findExecutable(named: "xcrun") else {
      return .failure(NSError(domain: "SimulatorService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "xcrun not found"]))
    }

    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("agenthub-devicectl-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = [
      "devicectl", "list", "devices",
      "--timeout", "5",
      "--json-output", outputURL.path
    ]

    process.standardOutput = Pipe()
    let errorPipe = Pipe()
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return .failure(error)
    }

    guard process.terminationStatus == 0 else {
      let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      return .failure(NSError(domain: "SimulatorService", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "devicectl list devices failed" : errorText]))
    }

    do {
      return .success(try parseDeviceCtlPhysicalDeviceList(from: Data(contentsOf: outputURL)))
    } catch {
      return .failure(error)
    }
  }

  /// Parses `xcrun xcdevice list --timeout 5` and returns connected physical iOS devices.
  private nonisolated static func fetchPhysicalDeviceListFromXCDevice() -> Result<[PhysicalIOSDevice], Error> {
    guard let xcrun = findExecutable(named: "xcrun") else {
      return .failure(NSError(domain: "SimulatorService", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "xcrun not found"]))
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = ["xcdevice", "list", "--timeout", "5"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return .failure(error)
    }

    guard process.terminationStatus == 0 else {
      return .failure(NSError(domain: "SimulatorService", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "xcdevice list failed"]))
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    do {
      return .success(try parsePhysicalDeviceList(from: data))
    } catch {
      return .failure(error)
    }
  }

  /// Parses the JSON produced by `xcrun simctl list devices --json`.
  nonisolated static func parseDeviceList(from data: Data) throws -> [SimulatorRuntime] {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let devicesMap = json["devices"] as? [String: [[String: Any]]] else {
      throw NSError(domain: "SimulatorService", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected JSON structure"])
    }

    var result: [SimulatorRuntime] = []

    for (runtimeIdentifier, rawDevices) in devicesMap {
      // Filter to iOS runtimes only
      guard runtimeIdentifier.contains("iOS") else { continue }

      let devices: [SimulatorDevice] = rawDevices.compactMap { dict in
        guard
          let udid = dict["udid"] as? String,
          let name = dict["name"] as? String,
          let state = dict["state"] as? String,
          let isAvailable = dict["isAvailable"] as? Bool
        else { return nil }
        let deviceTypeIdentifier = dict["deviceTypeIdentifier"] as? String ?? ""
        return SimulatorDevice(
          udid: udid,
          name: name,
          state: state,
          isAvailable: isAvailable,
          deviceTypeIdentifier: deviceTypeIdentifier
        )
      }

      let displayName = runtimeDisplayName(from: runtimeIdentifier)
      result.append(SimulatorRuntime(
        identifier: runtimeIdentifier,
        displayName: displayName,
        devices: devices
      ))
    }

    // Sort newest iOS version first
    return result.sorted { lhs, rhs in
      lhs.identifier > rhs.identifier
    }
  }

  /// Parses the JSON produced by `xcrun xcdevice list`.
  nonisolated static func parsePhysicalDeviceList(from data: Data) throws -> [PhysicalIOSDevice] {
    guard let rawDevices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw NSError(domain: "SimulatorService", code: -12,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected xcdevice JSON structure"])
    }

    let devices = rawDevices.compactMap { dict -> PhysicalIOSDevice? in
      guard
        (dict["simulator"] as? Bool) == false,
        (dict["available"] as? Bool) == true,
        let platform = dict["platform"] as? String,
        platform == "com.apple.platform.iphoneos",
        let identifier = dict["identifier"] as? String,
        let name = dict["name"] as? String
      else {
        return nil
      }

      let modelName = dict["modelName"] as? String ?? ""
      let operatingSystemVersion = dict["operatingSystemVersion"] as? String ?? ""
      let interface = dict["interface"] as? String
      return PhysicalIOSDevice(
        identifier: identifier,
        name: name,
        modelName: modelName,
        operatingSystemVersion: operatingSystemVersion,
        interface: interface
      )
    }

    return sortPhysicalDevices(devices)
  }

  /// Parses the JSON produced by `xcrun devicectl list devices --json-output`.
  nonisolated static func parseDeviceCtlPhysicalDeviceList(from data: Data) throws -> [PhysicalIOSDevice] {
    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let result = json["result"] as? [String: Any],
      let rawDevices = result["devices"] as? [[String: Any]]
    else {
      throw NSError(domain: "SimulatorService", code: -13,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected devicectl JSON structure"])
    }

    let devices = rawDevices.compactMap { dict -> PhysicalIOSDevice? in
      guard
        let hardware = dict["hardwareProperties"] as? [String: Any],
        (hardware["reality"] as? String) == "physical",
        (hardware["platform"] as? String) == "iOS",
        let udid = hardware["udid"] as? String,
        hasCoreDeviceRunCapabilities(dict)
      else {
        return nil
      }

      let deviceProperties = dict["deviceProperties"] as? [String: Any]
      let name = deviceProperties?["name"] as? String
        ?? hardware["marketingName"] as? String
        ?? udid
      let modelName = hardware["marketingName"] as? String
        ?? hardware["productType"] as? String
        ?? ""
      let osVersion = deviceProperties?["osVersionNumber"] as? String ?? ""
      let osBuild = deviceProperties?["osBuildUpdate"] as? String
      let formattedOSVersion: String
      if let osBuild, !osBuild.isEmpty, !osVersion.isEmpty {
        formattedOSVersion = "\(osVersion) (\(osBuild))"
      } else {
        formattedOSVersion = osVersion
      }

      return PhysicalIOSDevice(
        identifier: udid,
        name: name,
        modelName: modelName,
        operatingSystemVersion: formattedOSVersion,
        interface: nil
      )
    }

    return sortPhysicalDevices(devices)
  }

  private nonisolated static func hasCoreDeviceRunCapabilities(_ device: [String: Any]) -> Bool {
    guard let capabilities = device["capabilities"] as? [[String: Any]] else { return false }
    let identifiers = Set(capabilities.compactMap { $0["featureIdentifier"] as? String })
    return identifiers.contains("com.apple.coredevice.feature.installapp")
      && identifiers.contains("com.apple.coredevice.feature.launchapplication")
  }

  private nonisolated static func sortPhysicalDevices(
    _ devices: [PhysicalIOSDevice]
  ) -> [PhysicalIOSDevice] {
    devices.sorted {
      if $0.name != $1.name {
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      return $0.identifier < $1.identifier
    }
  }

  /// Converts a simctl runtime identifier to a human-readable display name.
  /// e.g. "com.apple.CoreSimulator.SimRuntime.iOS-17-5" → "iOS 17.5"
  nonisolated static func runtimeDisplayName(from identifier: String) -> String {
    // Extract the trailing component after the last dot, e.g. "iOS-17-5"
    guard let suffix = identifier.components(separatedBy: ".").last else {
      return identifier
    }
    // Replace hyphens with spaces/dots: "iOS-17-5" → "iOS 17.5"
    let parts = suffix.components(separatedBy: "-")
    guard parts.count >= 2 else { return suffix }
    let platform = parts[0] // "iOS"
    let versionParts = parts.dropFirst()
    let version = versionParts.joined(separator: ".")
    return "\(platform) \(version)"
  }

  /// Finds an executable by name in standard locations.
  private nonisolated static func findExecutable(named name: String) -> String? {
    let searchPaths = [
      "/usr/bin/\(name)",
      "/usr/local/bin/\(name)",
      "/opt/homebrew/bin/\(name)"
    ]
    return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
