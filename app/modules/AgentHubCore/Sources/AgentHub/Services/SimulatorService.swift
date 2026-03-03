//
//  SimulatorService.swift
//  AgentHub
//
//  Manages iOS Simulator lifecycle: listing devices, booting, shutting down.
//  Mirrors the DevServerManager pattern — @MainActor @Observable singleton
//  with UDID-keyed state and Task.detached for all process execution.
//

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

/// Result of the detection phase — workspace/project path, scheme, and xcodebuild path.
private struct BuildSetup: Sendable {
  let targetPath: String
  let isWorkspace: Bool
  let scheme: String
  let xcodebuild: String
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

  // MARK: - Public API

  /// Returns the combined state for a device in a given session's context.
  /// Build state (building/failed) is per-session; boot state (booted/booting/shuttingDown) is global.
  public func state(for udid: String, projectPath: String) -> SimulatorState {
    let key = sessionKey(projectPath: projectPath, udid: udid)
    if let buildState = sessionBuildStates[key] {
      switch buildState {
      case .building, .failed: return buildState
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
    let detectResult = await Task.detached {
      SimulatorService.detectBuildTarget(projectPath: projectPath)
    }.value

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
    var buildArgs = ["build", "-scheme", setup.scheme, "-destination", "platform=macOS,arch=arm64"]
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

  /// Builds for an iOS simulator, installs, and launches the app.
  public func buildAndRunOnSimulator(udid: String, projectPath: String) async {
    let key = sessionKey(projectPath: projectPath, udid: udid)
    sessionBuildStates[key] = .building
    AppLogger.simulator.info("Building for simulator \(udid)")

    // Phase 1: detect workspace/scheme off main actor
    let detectResult = await Task.detached {
      SimulatorService.detectBuildTarget(projectPath: projectPath)
    }.value

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
    var buildArgs = ["build", "-scheme", setup.scheme,
                     "-destination", "platform=iOS Simulator,id=\(udid)"]
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

    // Phase 3: execute off main actor
    let result = await Task.detached {
      SimulatorService.executeSimulatorBuild(ref: ref, udid: udid, setup: setup)
    }.value

    simulatorBuildProcesses.removeValue(forKey: key)

    guard sessionBuildStates[key] == .building else { return }

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
    sessionBuildStates.removeValue(forKey: key)
    AppLogger.simulator.info("Cancelled simulator build for \(udid)")
  }

  // MARK: - Key Helpers

  private func sessionKey(projectPath: String, udid: String) -> String {
    "\(projectPath)|\(udid)"
  }

  // MARK: - Process Helpers (nonisolated)

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
    guard let scheme = detectScheme(for: target) else {
      return .failure(NSError(domain: "SimulatorService", code: -4,
        userInfo: [NSLocalizedDescriptionKey: "No scheme found in project"]))
    }
    guard let xcodebuild = findExecutable(named: "xcodebuild") else {
      return .failure(NSError(domain: "SimulatorService", code: -5,
        userInfo: [NSLocalizedDescriptionKey: "xcodebuild not found"]))
    }
    return .success(BuildSetup(
      targetPath: target.path,
      isWorkspace: target.isWorkspace,
      scheme: scheme,
      xcodebuild: xcodebuild
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
    var stdoutChunks: [Data] = []
    let stdoutLock = NSLock()
    ref.outputPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      stdoutLock.lock()
      stdoutChunks.append(chunk)
      stdoutLock.unlock()
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
      let outputText = String(data: stdoutChunks.reduce(Data(), +), encoding: .utf8) ?? ""
      let stderrText = String(data: ref.errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let msg = SimulatorService.extractBuildError(outputText: outputText, stderrText: stderrText, exitCode: ref.process.terminationStatus)
      return .failure(NSError(domain: "SimulatorService",
        code: Int(ref.process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: msg]))
    }

    let target = (path: setup.targetPath, isWorkspace: setup.isWorkspace)
    guard let appPath = findBuiltAppPath(target: target, scheme: setup.scheme, xcodebuild: setup.xcodebuild) else {
      return .failure(NSError(domain: "SimulatorService", code: -6,
        userInfo: [NSLocalizedDescriptionKey: "Could not locate built app"]))
    }

    runOpenPath(appPath)
    return .success(appPath)
  }

  /// Runs xcodebuild for the given simulator UDID, then installs and launches the app.
  private nonisolated static func executeSimulatorBuild(
    ref: ProcessRef,
    udid: String,
    setup: BuildSetup
  ) -> Result<Void, Error> {
    var stdoutChunks: [Data] = []
    let stdoutLock = NSLock()
    ref.outputPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      stdoutLock.lock()
      stdoutChunks.append(chunk)
      stdoutLock.unlock()
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
      let outputText = String(data: stdoutChunks.reduce(Data(), +), encoding: .utf8) ?? ""
      let stderrText = String(data: ref.errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let msg = SimulatorService.extractBuildError(outputText: outputText, stderrText: stderrText, exitCode: ref.process.terminationStatus)
      return .failure(NSError(domain: "SimulatorService",
        code: Int(ref.process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: msg]))
    }

    return installAndLaunch(udid: udid, setup: setup)
  }

  /// Extracts build settings, boots the simulator, installs the app, and launches it.
  private nonisolated static func installAndLaunch(
    udid: String,
    setup: BuildSetup
  ) -> Result<Void, Error> {
    guard let xcodebuild = findExecutable(named: "xcodebuild"),
          let xcrun = findExecutable(named: "xcrun") else {
      return .failure(NSError(domain: "SimulatorService", code: -8,
        userInfo: [NSLocalizedDescriptionKey: "xcodebuild or xcrun not found"]))
    }

    // Get build settings for the simulator destination
    var settingsArgs = ["-showBuildSettings", "-scheme", setup.scheme,
                        "-destination", "platform=iOS Simulator,id=\(udid)"]
    if setup.isWorkspace {
      settingsArgs += ["-workspace", setup.targetPath]
    } else {
      settingsArgs += ["-project", setup.targetPath]
    }

    let settingsProcess = Process()
    settingsProcess.executableURL = URL(fileURLWithPath: xcodebuild)
    settingsProcess.arguments = settingsArgs
    let settingsPipe = Pipe()
    settingsProcess.standardOutput = settingsPipe
    settingsProcess.standardError = Pipe()
    do {
      try settingsProcess.run()
      settingsProcess.waitUntilExit()
    } catch {
      return .failure(error)
    }

    let output = String(data: settingsPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    var builtProductsDir: String?
    var productName: String?
    var bundleId: String?

    for line in output.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("BUILT_PRODUCTS_DIR = ") {
        builtProductsDir = String(trimmed.dropFirst("BUILT_PRODUCTS_DIR = ".count))
      } else if trimmed.hasPrefix("PRODUCT_NAME = ") {
        productName = String(trimmed.dropFirst("PRODUCT_NAME = ".count))
      } else if trimmed.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER = ") {
        bundleId = String(trimmed.dropFirst("PRODUCT_BUNDLE_IDENTIFIER = ".count))
      }
    }

    guard let dir = builtProductsDir, let name = productName, let bundle = bundleId else {
      return .failure(NSError(domain: "SimulatorService", code: -9,
        userInfo: [NSLocalizedDescriptionKey: "Could not read build settings"]))
    }

    let appPath = (dir as NSString).appendingPathComponent("\(name).app")

    // Boot simulator (ignore failure — it may already be booted)
    let bootProcess = Process()
    bootProcess.executableURL = URL(fileURLWithPath: xcrun)
    bootProcess.arguments = ["simctl", "boot", udid]
    bootProcess.standardOutput = Pipe()
    bootProcess.standardError = Pipe()
    try? bootProcess.run()
    bootProcess.waitUntilExit()

    // Install
    let installCode = runSimctl(arguments: ["install", udid, appPath])
    guard installCode == 0 else {
      return .failure(NSError(domain: "SimulatorService", code: Int(installCode),
        userInfo: [NSLocalizedDescriptionKey: "simctl install failed (exit \(installCode))"]))
    }

    // Launch
    let launchCode = runSimctl(arguments: ["launch", udid, bundle])
    guard launchCode == 0 else {
      return .failure(NSError(domain: "SimulatorService", code: Int(launchCode),
        userInfo: [NSLocalizedDescriptionKey: "simctl launch failed (exit \(launchCode))"]))
    }

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
    for target: (path: String, isWorkspace: Bool)
  ) -> String? {
    guard let xcodebuild = findExecutable(named: "xcodebuild") else { return nil }

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

  /// Runs `xcodebuild -showBuildSettings` and extracts the built .app path.
  private nonisolated static func findBuiltAppPath(
    target: (path: String, isWorkspace: Bool),
    scheme: String,
    xcodebuild: String
  ) -> String? {
    var args = ["-showBuildSettings", "-scheme", scheme,
                "-destination", "platform=macOS,arch=arm64"]
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

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    var builtProductsDir: String?
    var productName: String?

    for line in output.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("BUILT_PRODUCTS_DIR = ") {
        builtProductsDir = String(trimmed.dropFirst("BUILT_PRODUCTS_DIR = ".count))
      } else if trimmed.hasPrefix("PRODUCT_NAME = ") {
        productName = String(trimmed.dropFirst("PRODUCT_NAME = ".count))
      }
    }

    guard let dir = builtProductsDir, let name = productName else { return nil }
    return (dir as NSString).appendingPathComponent("\(name).app")
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
