import Foundation

// MARK: - Process abstraction

/// Minimal process runner so the artifact store's `xcodebuild`/`nm` calls can
/// be stubbed in tests.
public protocol HotReloadProcessRunning: Sendable {
  func run(
    executablePath: String,
    arguments: [String],
    currentDirectory: URL?
  ) async throws -> (exitCode: Int32, output: String)
}

public struct HotReloadProcessRunner: HotReloadProcessRunning {
  public init() {}

  public func run(
    executablePath: String,
    arguments: [String],
    currentDirectory: URL?
  ) async throws -> (exitCode: Int32, output: String) {
    try await Task.detached(priority: .utility) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executablePath)
      process.arguments = arguments
      if let currentDirectory {
        process.currentDirectoryURL = currentDirectory
      }
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      try process.run()
      // Drain before waiting so a chatty xcodebuild can't fill the pipe.
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let output = String(data: data, encoding: .utf8) ?? ""
      return (process.terminationStatus, output)
    }.value
  }
}

// MARK: - Artifact location

/// Finds the built support frameworks inside the wrapper package's derived
/// data. Pure directory inspection — unit-tested against fixture trees.
public enum HotReloadArtifactLocator {

  /// Searches `Build/Products` (built frameworks, including SwiftPM's
  /// `PackageFrameworks/`) and `SourcePackages/artifacts` (binary
  /// xcframework slices such as SnapshotPreviews' dynamic
  /// `PreviewsSupport.framework`).
  public static func locate(
    inDerivedData derivedData: URL,
    fileManager: FileManager = .default
  ) -> HotReloadArtifacts {
    let roots = [
      derivedData.appendingPathComponent("Build/Products", isDirectory: true),
      derivedData.appendingPathComponent("SourcePackages/artifacts", isDirectory: true),
    ]

    var injectionDylib: String?
    var previewHostDylib: String?
    var searchPaths: [String] = []

    for root in roots {
      guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else { continue }

      while let url = enumerator.nextObject() as? URL {
        guard url.pathExtension == "framework" else { continue }
        enumerator.skipDescendants()
        guard isSimulatorSlice(url.path) else { continue }

        let name = url.deletingPathExtension().lastPathComponent
        let binary = url.appendingPathComponent(name).path
        guard fileManager.fileExists(atPath: binary) else { continue }

        switch name {
        case HotReloadHostPackage.injectionScheme:
          injectionDylib = binary
          appendUnique(url.deletingLastPathComponent().path, to: &searchPaths)
        case HotReloadHostPackage.previewHostScheme:
          previewHostDylib = binary
          appendUnique(url.deletingLastPathComponent().path, to: &searchPaths)
        default:
          // Dependent framework (e.g. PreviewsSupport) — dyld just needs
          // its directory on the framework search path.
          appendUnique(url.deletingLastPathComponent().path, to: &searchPaths)
        }
      }
    }

    return HotReloadArtifacts(
      injectionDylibPath: injectionDylib,
      previewHostDylibPath: previewHostDylib,
      frameworkSearchPaths: searchPaths
    )
  }

  /// Keeps device/watch/tv slices of xcframeworks out of the simulator
  /// launch environment. Products-dir paths contain `Debug-iphonesimulator`;
  /// xcframework slices contain identifiers like `ios-arm64_x86_64-simulator`.
  static func isSimulatorSlice(_ path: String) -> Bool {
    for component in path.lowercased().split(separator: "/") {
      // xcframework slice identifiers: "ios-arm64", "ios-arm64_x86_64-simulator", …
      if let platform = ["ios", "watchos", "tvos", "xros", "macos"]
        .first(where: { component.hasPrefix($0 + "-") }) {
        return platform == "ios" && component.hasSuffix("-simulator")
      }
      // xcodebuild products dirs: "Debug-iphonesimulator", "Debug-iphoneos", …
      if component.contains("-iphonesimulator") { return true }
      if component.contains("-iphoneos") || component.contains("-watchos")
        || component.contains("-appletvos") || component.contains("-xros") {
        return false
      }
    }
    return true
  }

  private static func appendUnique(_ path: String, to paths: inout [String]) {
    if !paths.contains(path) { paths.append(path) }
  }
}

// MARK: - Store

public protocol HotReloadArtifactProviding: Sendable {
  /// Returns artifacts immediately if a valid cached build exists, else nil.
  func cachedArtifacts() async -> HotReloadArtifacts?
  /// Builds (or reuses) the support dylibs. Safe to call concurrently —
  /// a single build is shared. `progress` strings are user-facing.
  func prepareArtifacts(
    progress: (@Sendable (String) -> Void)?
  ) async throws -> HotReloadArtifacts
}

public enum HotReloadArtifactError: LocalizedError {
  case buildFailed(scheme: String, detail: String)
  case artifactsMissing

  public var errorDescription: String? {
    switch self {
    case .buildFailed(let scheme, let detail):
      return "Building \(scheme) for the simulator failed: \(detail)"
    case .artifactsMissing:
      return "Support build completed but no frameworks were produced"
    }
  }
}

/// Builds and caches the simulator-side support dylibs under
/// `~/Library/Application Support/AgentHub/HotReloadHost/`. The first build
/// resolves the pinned packages from the network and compiles for the iOS
/// simulator (a minute or two); afterwards everything is served from cache
/// until the pins (`HotReloadHostPackage.fingerprint`) change.
public actor HotReloadArtifactStore: HotReloadArtifactProviding {

  private let rootDirectory: URL
  private let runner: any HotReloadProcessRunning
  private let fileManager: FileManager
  private var inFlight: Task<HotReloadArtifacts, Error>?

  public init(
    rootDirectory: URL? = nil,
    runner: any HotReloadProcessRunning = HotReloadProcessRunner(),
    fileManager: FileManager = .default
  ) {
    self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory
    self.runner = runner
    self.fileManager = fileManager
  }

  public static var defaultRootDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("HotReloadHost", isDirectory: true)
  }

  private var packageDirectory: URL {
    rootDirectory.appendingPathComponent("package", isDirectory: true)
  }

  private var derivedDataDirectory: URL {
    rootDirectory.appendingPathComponent("DerivedData", isDirectory: true)
  }

  private var stampURL: URL {
    rootDirectory.appendingPathComponent("artifacts.stamp")
  }

  public func cachedArtifacts() async -> HotReloadArtifacts? {
    guard let stamp = try? String(contentsOf: stampURL, encoding: .utf8),
          stamp == HotReloadHostPackage.fingerprint
    else { return nil }
    let artifacts = HotReloadArtifactLocator.locate(
      inDerivedData: derivedDataDirectory, fileManager: fileManager
    )
    guard artifacts.previewHostDylibPath != nil
            || artifacts.injectionDylibPath != nil
    else { return nil }
    return artifacts
  }

  public func prepareArtifacts(
    progress: (@Sendable (String) -> Void)?
  ) async throws -> HotReloadArtifacts {
    if let cached = await cachedArtifacts() { return cached }
    if let inFlight { return try await inFlight.value }

    let task = Task { try await build(progress: progress) }
    inFlight = task
    defer { inFlight = nil }
    return try await task.value
  }

  private func build(
    progress: (@Sendable (String) -> Void)?
  ) async throws -> HotReloadArtifacts {
    try HotReloadHostPackage.write(to: packageDirectory, fileManager: fileManager)

    for scheme in [
      HotReloadHostPackage.previewHostScheme,
      HotReloadHostPackage.injectionScheme,
    ] {
      progress?("Building \(scheme) for the simulator…")
      let (exitCode, output) = try await runner.run(
        executablePath: "/usr/bin/xcodebuild",
        arguments: [
          "-scheme", scheme,
          "-configuration", "Debug",
          "-destination", "generic/platform=iOS Simulator",
          "-derivedDataPath", derivedDataDirectory.path,
          "COMPILER_INDEX_STORE_ENABLE=NO",
          "build",
        ],
        currentDirectory: packageDirectory
      )
      guard exitCode == 0 else {
        throw HotReloadArtifactError.buildFailed(
          scheme: scheme, detail: Self.buildFailureSummary(from: output)
        )
      }
    }

    var artifacts = HotReloadArtifactLocator.locate(
      inDerivedData: derivedDataDirectory, fileManager: fileManager
    )
    guard artifacts.injectionDylibPath != nil
            || artifacts.previewHostDylibPath != nil
    else {
      throw HotReloadArtifactError.artifactsMissing
    }

    artifacts = await validateInjectionBoot(in: artifacts, progress: progress)

    try? fileManager.createDirectory(
      at: rootDirectory, withIntermediateDirectories: true
    )
    try HotReloadHostPackage.fingerprint.write(
      to: stampURL, atomically: true, encoding: .utf8
    )
    return artifacts
  }

  /// Confirms the InjectionLite boot machinery survived linking (`-all_load`)
  /// by checking the dylib's symbol table. If it didn't, the injection dylib
  /// would load but never start — drop it so the pill reports "unavailable"
  /// instead of silently doing nothing.
  private func validateInjectionBoot(
    in artifacts: HotReloadArtifacts,
    progress: (@Sendable (String) -> Void)?
  ) async -> HotReloadArtifacts {
    guard let injectionDylib = artifacts.injectionDylibPath else {
      return artifacts
    }
    guard let (exitCode, output) = try? await runner.run(
      executablePath: "/usr/bin/xcrun",
      arguments: ["nm", injectionDylib],
      currentDirectory: nil
    ), exitCode == 0 else {
      return artifacts // nm unavailable — don't block on the safety check
    }
    if output.contains("InjectionBoot") || output.contains("InjectionLite") {
      return artifacts
    }
    progress?("Injection engine was stripped from the support build — hot reload disabled")
    return HotReloadArtifacts(
      injectionDylibPath: nil,
      previewHostDylibPath: artifacts.previewHostDylibPath,
      frameworkSearchPaths: artifacts.frameworkSearchPaths
    )
  }

  private static func buildFailureSummary(from output: String) -> String {
    let lines = output.components(separatedBy: .newlines)
    if let errorLine = lines.first(where: { $0.contains("error:") }) {
      return errorLine.trimmingCharacters(in: .whitespaces)
    }
    return lines.suffix(3).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }
}
