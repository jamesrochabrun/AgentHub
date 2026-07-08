import Foundation
import Testing

@testable import SimulatorPreview

@Suite("HotReloadHostPackage")
struct HotReloadHostPackageTests {

  @Test("manifest pins the upstream packages to exact released versions")
  func manifestPins() {
    let manifest = HotReloadHostPackage.manifest
    #expect(manifest.contains(
      "https://github.com/getsentry/SnapshotPreviews.git"))
    #expect(manifest.contains(
      "exact: \"\(HotReloadHostPackage.snapshotPreviewsVersion)\""))
    #expect(manifest.contains(
      "https://github.com/johnno1962/InjectionLite.git"))
    #expect(manifest.contains(
      "exact: \"\(HotReloadHostPackage.injectionLiteVersion)\""))
    #expect(manifest.contains(
      "https://github.com/swhitty/FlyingFox.git"))
    #expect(manifest.contains("-all_load"))
    #expect(manifest.contains("type: .dynamic"))
  }

  @Test("the boot constructors unbuffer stdout and gate the preview host")
  func bootConstructors() {
    let files = HotReloadHostPackage.sourceFiles
    #expect(files["Sources/CAgentHubUnbuffer/unbuffer.c"]?
      .contains("setvbuf(stdout, NULL, _IOLBF, 0)") == true)
    #expect(files["Sources/CAgentHubPreviewBoot/boot.c"]?
      .contains("getenv(\"\(HotReloadHostPackage.previewHostEnvironmentKey)\")") == true)
    // The host must never use the stock UIKit strategy — it covers the live
    // app with a full-screen render window. It renders with a plain
    // ImageRenderer at device scale (the default 1x is what made early
    // snapshots blurry) and reports the scale for point-true display.
    let host = files["Sources/\(HotReloadHostPackage.previewHostScheme)/\(HotReloadHostPackage.previewHostScheme).swift"]
    #expect(host?.contains("UIKitRenderingStrategy") == false)
    #expect(host?.contains("renderer.scale = scale") == true)
    #expect(host?.contains("result[\"scale\"]") == true)
  }

  @Test("the host binds the per-device port from the launch environment")
  func hostReadsPortFromEnvironment() {
    let host = HotReloadHostPackage.sourceFiles[
      "Sources/\(HotReloadHostPackage.previewHostScheme)/\(HotReloadHostPackage.previewHostScheme).swift"]
    #expect(host?.contains(
      "environment[\"\(HotReloadHostPackage.previewPortEnvironmentKey)\"]") == true)
    #expect(host?.contains("?? \(HotReloadHostPackage.previewHostDefaultPort)") == true)
    #expect(host?.contains("port: AgentHubPreviewHost.configuredPort") == true)
  }

  /// Pins the generated host's status lines to what
  /// `PreviewHostStatusParser` understands — same discipline as the
  /// InjectionLite console pins: change them together.
  @Test("the host prints the structured status lines the parser understands")
  func hostPrintsParsableStatusLines() {
    let host = HotReloadHostPackage.sourceFiles[
      "Sources/\(HotReloadHostPackage.previewHostScheme)/\(HotReloadHostPackage.previewHostScheme).swift"]

    #expect(host?.contains(
      "AGENTHUB_PREVIEW_HOST: unsupported reason=ios-version") == true)
    #expect(host?.contains(
      "AGENTHUB_PREVIEW_HOST: waiting reason=app-not-active") == true)
    #expect(host?.contains("AGENTHUB_PREVIEW_HOST: listening ") == true)
    #expect(host?.contains("AGENTHUB_PREVIEW_HOST: failed reason=port-in-use ") == true)
    #expect(host?.contains("AGENTHUB_PREVIEW_HOST: failed reason=server-error ") == true)
    #expect(host?.contains("waitUntilListening") == true)

    // And the parser accepts the exact shapes the host emits.
    let parser = PreviewHostStatusParser()
    #expect(parser.parse(
      line: "AGENTHUB_PREVIEW_HOST: unsupported reason=ios-version") != nil)
    #expect(parser.parse(
      line: "AGENTHUB_PREVIEW_HOST: waiting reason=app-not-active") != nil)
    #expect(parser.parse(line: "AGENTHUB_PREVIEW_HOST: listening port=38824") != nil)
    #expect(parser.parse(
      line: "AGENTHUB_PREVIEW_HOST: failed reason=port-in-use port=38824") != nil)
    #expect(parser.parse(
      line: "AGENTHUB_PREVIEW_HOST: failed reason=server-error detail=boom") != nil)
  }

  @Test("fingerprint is a deterministic content hash")
  func fingerprintDeterminism() {
    #expect(HotReloadHostPackage.fingerprint.hasPrefix("host-sha256-"))
    #expect(HotReloadHostPackage.fingerprint == HotReloadHostPackage.fingerprint(
      manifest: HotReloadHostPackage.manifest,
      sourceFiles: HotReloadHostPackage.sourceFiles
    ))
  }

  @Test("fingerprint changes when the manifest or any generated source changes")
  func fingerprintSensitivity() {
    let manifest = HotReloadHostPackage.manifest
    var sources = HotReloadHostPackage.sourceFiles
    let base = HotReloadHostPackage.fingerprint(manifest: manifest, sourceFiles: sources)

    let manifestVariant = HotReloadHostPackage.fingerprint(
      manifest: manifest + "\n// pin bump",
      sourceFiles: sources
    )
    #expect(manifestVariant != base)

    let key = sources.keys.sorted()[0]
    sources[key] = (sources[key] ?? "") + "\n// edited"
    let sourceVariant = HotReloadHostPackage.fingerprint(manifest: manifest, sourceFiles: sources)
    #expect(sourceVariant != base)
    #expect(sourceVariant != manifestVariant)
  }

  @Test("write is idempotent and only touches changed files")
  func writeIdempotent() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hot-reload-host-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try HotReloadHostPackage.write(to: directory) == true)
    #expect(try HotReloadHostPackage.write(to: directory) == false)

    let manifestURL = directory.appendingPathComponent("Package.swift")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    #expect(manifest == HotReloadHostPackage.manifest)

    for relativePath in HotReloadHostPackage.sourceFiles.keys {
      #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(relativePath).path))
    }
  }
}

@Suite("HotReloadArtifactLocator")
struct HotReloadArtifactLocatorTests {

  /// Builds a fake derived-data tree mirroring an SPM xcodebuild layout.
  private func makeDerivedData(
    includeDeviceSlice: Bool = false
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("hot-reload-dd-\(UUID().uuidString)")
    let fileManager = FileManager.default

    func addFramework(_ name: String, at relative: String) throws {
      let framework = root
        .appendingPathComponent(relative, isDirectory: true)
        .appendingPathComponent("\(name).framework", isDirectory: true)
      try fileManager.createDirectory(at: framework, withIntermediateDirectories: true)
      fileManager.createFile(
        atPath: framework.appendingPathComponent(name).path,
        contents: Data([0xCA, 0xFE])
      )
    }

    let products = "Build/Products/Debug-iphonesimulator/PackageFrameworks"
    try addFramework("AgentHubPreviewHost", at: products)
    try addFramework("AgentHubInjection", at: products)
    try addFramework(
      "PreviewsSupport",
      at: "SourcePackages/artifacts/snapshotpreviews/PreviewsSupport/"
        + "PreviewsSupport.xcframework/ios-arm64_x86_64-simulator"
    )
    if includeDeviceSlice {
      try addFramework(
        "PreviewsSupport",
        at: "SourcePackages/artifacts/snapshotpreviews/PreviewsSupport/"
          + "PreviewsSupport.xcframework/ios-arm64"
      )
    }
    return root
  }

  @Test("locates dylibs and framework search paths")
  func locates() throws {
    let root = try makeDerivedData()
    defer { try? FileManager.default.removeItem(at: root) }

    let artifacts = HotReloadArtifactLocator.locate(inDerivedData: root)

    #expect(artifacts.injectionDylibPath?.hasSuffix(
      "PackageFrameworks/AgentHubInjection.framework/AgentHubInjection") == true)
    #expect(artifacts.previewHostDylibPath?.hasSuffix(
      "PackageFrameworks/AgentHubPreviewHost.framework/AgentHubPreviewHost") == true)
    #expect(artifacts.frameworkSearchPaths.count == 2)
    #expect(artifacts.frameworkSearchPaths.contains {
      $0.hasSuffix("ios-arm64_x86_64-simulator")
    })
  }

  @Test("device slices are excluded from search paths")
  func excludesDeviceSlices() throws {
    let root = try makeDerivedData(includeDeviceSlice: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let artifacts = HotReloadArtifactLocator.locate(inDerivedData: root)
    #expect(!artifacts.frameworkSearchPaths.contains {
      $0.hasSuffix("/ios-arm64")
    })
  }

  @Test("simulator slice predicate")
  func slicePredicate() {
    #expect(HotReloadArtifactLocator.isSimulatorSlice(
      "/dd/Build/Products/Debug-iphonesimulator/PackageFrameworks/X.framework"))
    #expect(HotReloadArtifactLocator.isSimulatorSlice(
      "/dd/SourcePackages/artifacts/p/X.xcframework/ios-arm64_x86_64-simulator/X.framework"))
    #expect(!HotReloadArtifactLocator.isSimulatorSlice(
      "/dd/SourcePackages/artifacts/p/X.xcframework/ios-arm64/X.framework"))
    #expect(!HotReloadArtifactLocator.isSimulatorSlice(
      "/dd/SourcePackages/artifacts/p/X.xcframework/watchos-arm64_x86_64-simulator/X.framework"))
    #expect(!HotReloadArtifactLocator.isSimulatorSlice(
      "/dd/Build/Products/Debug-iphoneos/X.framework"))
  }
}

@Suite("HotReloadArtifactStore")
struct HotReloadArtifactStoreTests {

  /// Runner that records invocations and fabricates the build products the
  /// real xcodebuild would emit.
  private actor RecordingRunner: HotReloadProcessRunning {
    private(set) var invocations: [[String]] = []
    let derivedData: URL
    var nmOutput = "_OBJC_CLASS_$_InjectionLite\nInjectionBoot"

    init(derivedData: URL) {
      self.derivedData = derivedData
    }

    func run(
      executablePath: String,
      arguments: [String],
      currentDirectory: URL?
    ) async throws -> (exitCode: Int32, output: String) {
      invocations.append([executablePath] + arguments)

      if executablePath.hasSuffix("xcodebuild") {
        let products = derivedData.appendingPathComponent(
          "Build/Products/Debug-iphonesimulator/PackageFrameworks")
        for name in ["AgentHubPreviewHost", "AgentHubInjection"] {
          let framework = products.appendingPathComponent("\(name).framework")
          try FileManager.default.createDirectory(
            at: framework, withIntermediateDirectories: true)
          FileManager.default.createFile(
            atPath: framework.appendingPathComponent(name).path,
            contents: Data([0x1]))
        }
        return (0, "BUILD SUCCEEDED")
      }
      return (0, nmOutput) // xcrun nm
    }

    func setNMOutput(_ output: String) {
      nmOutput = output
    }
  }

  @Test("prepare builds both schemes, validates, stamps, and caches")
  func prepareAndCache() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("hot-reload-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingRunner(
      derivedData: root.appendingPathComponent("DerivedData"))
    let store = HotReloadArtifactStore(rootDirectory: root, runner: runner)

    #expect(await store.cachedArtifacts() == nil)

    let artifacts = try await store.prepareArtifacts(progress: nil)
    #expect(artifacts.injectionDylibPath != nil)
    #expect(artifacts.previewHostDylibPath != nil)

    let buildInvocations = await runner.invocations.filter {
      $0[0].hasSuffix("xcodebuild")
    }
    #expect(buildInvocations.count == 2)
    #expect(buildInvocations.allSatisfy {
      $0.contains("generic/platform=iOS Simulator")
    })

    // Second call is served from the stamp + existing artifacts.
    _ = try await store.prepareArtifacts(progress: nil)
    #expect(await runner.invocations.filter { $0[0].hasSuffix("xcodebuild") }.count == 2)
    #expect(await store.cachedArtifacts() != nil)
  }

  @Test("stripped injection boot drops the injection dylib only")
  func strippedBoot() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("hot-reload-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingRunner(
      derivedData: root.appendingPathComponent("DerivedData"))
    await runner.setNMOutput("no boot symbols here")
    let store = HotReloadArtifactStore(rootDirectory: root, runner: runner)

    let artifacts = try await store.prepareArtifacts(progress: nil)
    #expect(artifacts.injectionDylibPath == nil)
    #expect(artifacts.previewHostDylibPath != nil)
  }
}
