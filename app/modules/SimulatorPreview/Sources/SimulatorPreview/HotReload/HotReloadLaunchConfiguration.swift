import Foundation

/// Paths to the runtime-support dylibs built by `HotReloadArtifactStore`,
/// plus the framework search paths dyld needs to resolve their dependencies
/// (e.g. SnapshotPreviews' dynamic `PreviewsSupport.framework`).
public struct HotReloadArtifacts: Equatable, Sendable {
  /// `AgentHubInjection.framework/AgentHubInjection` — embeds InjectionLite,
  /// which self-boots via `+load` and hot-swaps saved Swift files.
  public let injectionDylibPath: String?
  /// `AgentHubPreviewHost.framework/AgentHubPreviewHost` — our generated
  /// SnapshotPreviewsCore-based host that serves previews over loopback.
  public let previewHostDylibPath: String?
  /// Directories containing the frameworks above and their dependencies.
  public let frameworkSearchPaths: [String]

  public init(
    injectionDylibPath: String?,
    previewHostDylibPath: String?,
    frameworkSearchPaths: [String]
  ) {
    self.injectionDylibPath = injectionDylibPath
    self.previewHostDylibPath = previewHostDylibPath
    self.frameworkSearchPaths = frameworkSearchPaths
  }
}

/// A ready-to-use hot-reload launch: the configuration plus where the app's
/// stdout should be redirected so the injection engine's events can be tailed.
public struct HotReloadLaunchPlan: Equatable, Sendable {
  public let configuration: HotReloadLaunchConfiguration
  /// Console log path for `--stdout=`; nil when neither the injection
  /// engine nor the preview host is inserted (both report through it —
  /// engine events and host startup status).
  public let consoleStdoutPath: String?

  public init(
    configuration: HotReloadLaunchConfiguration,
    consoleStdoutPath: String?
  ) {
    self.configuration = configuration
    self.consoleStdoutPath = consoleStdoutPath
  }
}

/// Everything `simctl launch` and `xcodebuild` need to arm hot reload and
/// the preview host for one app launch. Pure data + pure derivations so the
/// exact environment contract is unit-testable.
public struct HotReloadLaunchConfiguration: Equatable, Sendable {
  public let projectPath: String
  public let artifacts: HotReloadArtifacts
  public let enableInjection: Bool
  public let enablePreviews: Bool
  /// Per-device loopback port for the preview host (see
  /// `PreviewHostPortAllocator`); nil falls back to the host's built-in
  /// default port.
  public let previewPort: Int?

  public init(
    projectPath: String,
    artifacts: HotReloadArtifacts,
    enableInjection: Bool,
    enablePreviews: Bool,
    previewPort: Int? = nil
  ) {
    self.projectPath = projectPath
    self.artifacts = artifacts
    self.enableInjection = enableInjection
    self.enablePreviews = enablePreviews
    self.previewPort = previewPort
  }

  /// True if at least one runtime feature will actually be armed.
  public var isEffective: Bool {
    (enableInjection && artifacts.injectionDylibPath != nil)
      || (enablePreviews && artifacts.previewHostDylibPath != nil)
  }

  /// `xcodebuild` build-setting overrides required by the injection engine:
  /// `-interposable` so injected dispatch can be rebound at function level,
  /// and `EMIT_FRONTEND_COMMAND_LINES` so Xcode 16.3+ build logs contain the
  /// per-file swift-frontend commands InjectionLite replays.
  public var xcodebuildSettingOverrides: [String] {
    guard enableInjection else { return [] }
    return [
      "OTHER_LDFLAGS=$(inherited) -Xlinker -interposable",
      "EMIT_FRONTEND_COMMAND_LINES=YES",
    ]
  }

  /// `simctl launch` arguments for a hot-reload launch: replace any running
  /// copy of the app, and redirect stdout to the console log we tail for
  /// injection-engine events (stderr goes to a sibling file so interleaved
  /// writes can't corrupt the parsed stream).
  public func launchArguments(consoleStdoutPath: String?) -> [String] {
    var arguments = ["--terminate-running-process"]
    if let consoleStdoutPath {
      arguments.append("--stdout=\(consoleStdoutPath)")
      arguments.append("--stderr=\(consoleStdoutPath).stderr")
    }
    return arguments
  }

  /// Environment for the `simctl launch` process. simctl forwards variables
  /// prefixed `SIMCTL_CHILD_` (prefix stripped) into the launched app.
  ///
  /// - `DYLD_INSERT_LIBRARIES`: the enabled support dylibs.
  /// - `DYLD_FRAMEWORK_PATH`: where dyld resolves their dependent frameworks.
  /// - `AGENTHUB_PREVIEW_HOST=1`: gates our preview host's boot constructor
  ///   (it starts its loopback server only when AgentHub armed the launch).
  /// - `AGENTHUB_PREVIEW_PORT`: the per-device loopback port the host binds.
  /// - `INJECTION_DIRECTORIES`: scopes InjectionLite's FSEvents watcher to
  ///   the project, plus `~/Library` so it can discover the build log under
  ///   AgentHub's custom derived-data path.
  public func simctlChildEnvironment(
    homeDirectory: String = NSHomeDirectory()
  ) -> [String: String] {
    var insertedLibraries: [String] = []
    var environment: [String: String] = [:]

    if enableInjection, let injection = artifacts.injectionDylibPath {
      insertedLibraries.append(injection)
      let library = (homeDirectory as NSString).appendingPathComponent("Library")
      environment["SIMCTL_CHILD_INJECTION_DIRECTORIES"] =
        "\(projectPath),\(library)"
    }
    if enablePreviews, let previewHost = artifacts.previewHostDylibPath {
      insertedLibraries.append(previewHost)
      environment[
        "SIMCTL_CHILD_\(HotReloadHostPackage.previewHostEnvironmentKey)"] = "1"
      if let previewPort {
        environment[
          "SIMCTL_CHILD_\(HotReloadHostPackage.previewPortEnvironmentKey)"] =
          String(previewPort)
      }
    }

    guard !insertedLibraries.isEmpty else { return [:] }

    environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] =
      insertedLibraries.joined(separator: ":")
    if !artifacts.frameworkSearchPaths.isEmpty {
      environment["SIMCTL_CHILD_DYLD_FRAMEWORK_PATH"] =
        artifacts.frameworkSearchPaths.joined(separator: ":")
    }
    return environment
  }
}
