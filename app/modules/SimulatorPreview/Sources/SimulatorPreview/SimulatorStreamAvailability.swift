import Foundation

/// Decides which capture backend the host machine supports.
///
/// The CoreSimulator backend needs Apple's private CoreSimulator and
/// SimulatorKit frameworks on disk (both ship with Xcode). When either is
/// missing — or symbol resolution fails later at runtime — sessions degrade to
/// the public `simctl io screenshot` polling backend, which is view-only.
public struct SimulatorStreamAvailability: Equatable, Sendable {
  public let backend: SimulatorStreamBackendKind
  public let coreSimulatorFrameworkPath: String?
  public let simulatorKitFrameworkPath: String?

  public var isInteractive: Bool { backend == .coreSimulator }

  public static let coreSimulatorBinaryPath =
    "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"

  /// Probe with injectable file checks so the decision is unit-testable.
  public static func probe(
    developerDir: String,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> SimulatorStreamAvailability {
    let simulatorKitPath = developerDir
      + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"

    let coreSimPath: String? = fileExists(coreSimulatorBinaryPath) ? coreSimulatorBinaryPath : nil
    let simKitPath: String? = fileExists(simulatorKitPath) ? simulatorKitPath : nil

    let backend: SimulatorStreamBackendKind =
      (coreSimPath != nil && simKitPath != nil) ? .coreSimulator : .screenshotPolling
    return SimulatorStreamAvailability(
      backend: backend,
      coreSimulatorFrameworkPath: coreSimPath,
      simulatorKitFrameworkPath: simKitPath
    )
  }

  public init(
    backend: SimulatorStreamBackendKind,
    coreSimulatorFrameworkPath: String?,
    simulatorKitFrameworkPath: String?
  ) {
    self.backend = backend
    self.coreSimulatorFrameworkPath = coreSimulatorFrameworkPath
    self.simulatorKitFrameworkPath = simulatorKitFrameworkPath
  }
}

/// Resolves the active Xcode developer directory once per process.
public enum XcodeDeveloperDirectory {
  static let fallback = "/Applications/Xcode.app/Contents/Developer"

  public static let resolved: String = {
    // Prefer the env var Xcode/xcrun set — no subprocess needed.
    if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !env.isEmpty {
      return env
    }
    return resolveViaXcodeSelect()
  }()

  /// Runs `xcode-select -p` WITHOUT spinning the runloop.
  ///
  /// This is load-bearing: `resolved` may first be touched while SwiftUI is
  /// evaluating a view body on the main thread. `Process.waitUntilExit()` pumps
  /// the main runloop, which re-enters SwiftUI layout and recursively hits the
  /// same `dispatch_once` token that is initializing this value (and the
  /// `SimulatorStreamService.shared` token above it) — Swift traps on the
  /// recursive `dispatch_once`. Reading the pipe to EOF blocks on `read(2)`
  /// instead, so nothing re-enters. We deliberately do not call
  /// `waitUntilExit()`; Foundation reaps the child on its own.
  private static func resolveViaXcodeSelect() -> String {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return fallback
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let output, !output.isEmpty {
      return output
    }
    return fallback
  }
}
