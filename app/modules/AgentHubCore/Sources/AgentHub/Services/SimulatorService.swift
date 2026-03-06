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

private final class DataAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var chunks: [Data] = []

  func append(_ chunk: Data) {
    lock.lock()
    chunks.append(chunk)
    lock.unlock()
  }

  func combinedData() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return chunks.reduce(Data(), +)
  }
}

/// Result of the detection phase — workspace/project path, scheme, and xcodebuild path.
private struct BuildSetup: Sendable {
  let targetPath: String
  let isWorkspace: Bool
  let scheme: String
  let xcodebuild: String
  let derivedDataPath: String
}

private struct BuiltAppInfo: Sendable {
  let appPath: String
  let bundleIdentifier: String?
}

private enum BuildPlatform {
  case macOS
  case iOSSimulator

  var productsDirectoryName: String {
    switch self {
    case .macOS:
      return "Debug"
    case .iOSSimulator:
      return "Debug-iphonesimulator"
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

  // MARK: - Observable State

  /// Per-UDID global boot/shutdown state, shared across all sessions
  private(set) var deviceStates: [String: SimulatorState] = [:]

  /// Per-(projectPath|UDID) build state — isolated per worktree session
  private(set) var sessionBuildStates: [String: SimulatorState] = [:]

  /// Cached list of runtimes with their available devices
  private(set) var runtimes: [SimulatorRuntime] = []

  /// True while the device list is being fetched
  private(set) var isLoadingDevices: Bool = false

  /// Per-projectPath macOS build-and-run state
  private(set) var macRunStates: [String: MacRunState] = [:]

  /// Live process references for in-flight Mac builds, keyed by projectPath
  private var macBuildProcesses: [String: ProcessRef] = [:]

  /// Live process references for in-flight simulator builds, keyed by projectPath|UDID
  private var simulatorBuildProcesses: [String: ProcessRef] = [:]

  /// In-flight Phase 3 tasks for simulator builds, keyed by projectPath|UDID
  private var simulatorRunTasks: [String: Task<Result<Void, Error>, Never>] = [:]

  /// Cached workspace/project and scheme selection per project path.
  private var buildSetupCache: [String: BuildSetup] = [:]

  // MARK: - Public API

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

  /// Fetches the device list from `xcrun simctl list devices --json`.
  /// Filters to iOS runtimes only, sorts newest first.
  public func listDevices() async {
    guard !isLoadingDevices else { return }
    isLoadingDevices = true
    defer { isLoadingDevices = false }

    let result = await Task.detached {
      SimulatorService.fetchDeviceList()
    }.value

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
  }

  /// Boots a simulator device by UDID, then opens Simulator.app.
  public func bootDevice(udid: String) async {
    deviceStates[udid] = .booting
    AppLogger.simulator.info("Booting device \(udid)")

    let exitCode = await Task.detached {
      SimulatorService.runSimctl(arguments: ["boot", udid])
    }.value

    if exitCode == 0 {
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
  public func buildAndRunOnSimulator(udid: String, projectPath: String) async {
    let key = sessionKey(projectPath: projectPath, udid: udid)
    sessionBuildStates[key] = .building
    AppLogger.simulator.info("Building for simulator \(udid)")

    // Phase 1: detect workspace/scheme off main actor
    let detectResult = await buildSetup(for: projectPath)

    guard case .success(let setup) = detectResult else {
      if case .failure(let e) = detectResult {
        sessionBuildStates[key] = .failed(error: e.localizedDescription)
        AppLogger.simulator.error("Simulator build setup failed: \(e.localizedDescription)")
      }
      return
    }

    // Phase 2: configure process on main actor and store for cancellation
    let process = Process()
    process.executableURL = URL(fileURLWithPath: setup.xcodebuild)
    var buildArgs = [
      "build",
      "-quiet",
      "-scheme", setup.scheme,
      "-destination", "generic/platform=iOS Simulator",
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
    simulatorBuildProcesses[key] = ref

    // Phase 3: execute off main actor; store the task so cancelSimulatorBuild can cancel it
    let phase3Task = Task.detached {
      await SimulatorService.executeSimulatorBuild(ref: ref, udid: udid, sessionKey: key, setup: setup)
    }
    simulatorRunTasks[key] = phase3Task
    let result = await phase3Task.value
    simulatorRunTasks.removeValue(forKey: key)

    simulatorBuildProcesses.removeValue(forKey: key)

    // Guard against a cancel() call that already removed the key from sessionBuildStates.
    // We can't check for .building here because installAndLaunch mutates the state to
    // .installing / .launching while Phase 3 is still in flight.
    guard sessionBuildStates[key] != nil else { return }

    switch result {
    case .success:
      sessionBuildStates.removeValue(forKey: key)
      deviceStates[udid] = .booted
      AppLogger.simulator.info("Simulator build+run succeeded for \(udid)")
    case .failure(let error):
      sessionBuildStates[key] = .failed(error: error.localizedDescription)
      AppLogger.simulator.error("Simulator build failed: \(error.localizedDescription)")
    }
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
  private nonisolated static func runSimctl(arguments: [String]) -> Int32 {
    guard let xcrun = findExecutable(named: "xcrun") else {
      AppLogger.simulator.error("xcrun not found in PATH")
      return -1
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrun)
    process.arguments = ["simctl"] + arguments
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

  /// Phase 3: runs the already-configured process, waits for it, finds and opens the app.
  private nonisolated static func executeBuild(
    ref: ProcessRef,
    setup: BuildSetup
  ) -> Result<String, Error> {
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
      // Terminated by signal means the user cancelled — return a benign error
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
    setup: BuildSetup
  ) async -> Result<Void, Error> {
    let totalStart = phaseTimestamp()
    let bootTask = Task.detached(priority: .utility) {
      SimulatorService.runSimctl(arguments: ["boot", udid])
    }

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
      "xcodebuild finished for scheme \(setup.scheme, privacy: .public) in \(formattedElapsed(since: buildStart), privacy: .public)s"
    )

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
      setup: setup
    )

    if case .success = result {
      AppLogger.simulator.info(
        "Simulator run completed in \(formattedElapsed(since: totalStart), privacy: .public)s for scheme \(setup.scheme, privacy: .public)"
      )
    }

    return result
  }

  /// Locates the built simulator app, installs it, and launches it.
  private nonisolated static func installAndLaunch(
    udid: String,
    sessionKey: String,
    setup: BuildSetup
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

    // Launch
    let launchStart = phaseTimestamp()
    let launchCode = runSimctl(arguments: ["launch", udid, bundle])
    guard launchCode == 0 else {
      return .failure(NSError(domain: "SimulatorService", code: Int(launchCode),
        userInfo: [NSLocalizedDescriptionKey: "simctl launch failed (exit \(launchCode))"]))
    }
    AppLogger.simulator.info(
      "Launched app in \(formattedElapsed(since: launchStart), privacy: .public)s"
    )

    // Bring Simulator.app to foreground
    runOpenApp(name: "Simulator")
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

  nonisolated static func preferredAppBundlePath(
    in productsDirectory: String,
    preferredAppName: String
  ) -> String? {
    let directoryURL = URL(fileURLWithPath: productsDirectory, isDirectory: true)
    guard let candidates = try? FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }

    let apps = candidates.filter { $0.pathExtension == "app" }
    guard !apps.isEmpty else { return nil }

    let preferredBundleName = "\(preferredAppName).app".lowercased()

    func rank(for url: URL) -> (Int, Date) {
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

      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return (score, modified)
    }

    let bestCandidate = apps.sorted { lhs, rhs in
      let left = rank(for: lhs)
      let right = rank(for: rhs)
      if left.0 != right.0 {
        return left.0 > right.0
      }
      return left.1 > right.1
    }.first

    return bestCandidate?.path
  }

  nonisolated static func bundleIdentifier(atAppPath appPath: String) -> String? {
    let infoPlistPath = (appPath as NSString).appendingPathComponent("Info.plist")
    guard let plist = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any] else {
      return nil
    }
    return plist["CFBundleIdentifier"] as? String
  }

  private nonisolated static func resolveBuiltApp(
    derivedDataPath: String,
    scheme: String,
    platform: BuildPlatform,
    requiresBundleIdentifier: Bool
  ) -> BuiltAppInfo? {
    let productsDirectory = (derivedDataPath as NSString)
      .appendingPathComponent("Build/Products/\(platform.productsDirectoryName)")
    guard let appPath = preferredAppBundlePath(
      in: productsDirectory,
      preferredAppName: scheme
    ) else {
      return nil
    }

    let bundleIdentifier = requiresBundleIdentifier ? bundleIdentifier(atAppPath: appPath) : nil
    if requiresBundleIdentifier && bundleIdentifier == nil {
      return nil
    }

    return BuiltAppInfo(appPath: appPath, bundleIdentifier: bundleIdentifier)
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
