import Foundation
import Testing
@testable import AgentHubCore

@Suite("BuildCacheService")
struct BuildCacheServiceTests {

  @Test func prepareForLaunchMigratesLegacyXcodeAndDeletesKnownModuleBuilds() async throws {
    let root = temporaryDirectory()
    let cacheRoot = root.appendingPathComponent("Caches/AgentHub", isDirectory: true)
    let legacyBuilds = root.appendingPathComponent("Application Support/AgentHub/Builds", isDirectory: true)
    let workspace = root.appendingPathComponent("Project", isDirectory: true)
    let module = workspace.appendingPathComponent("app/modules/AgentHubCore", isDirectory: true)
    let legacyBuild = legacyBuilds.appendingPathComponent(BuildCachePaths.workspaceHash(for: workspace.path), isDirectory: true)

    try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
    try "package".write(to: module.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: module.appendingPathComponent(".build", isDirectory: true), withIntermediateDirectories: true)
    try "artifact".write(to: module.appendingPathComponent(".build/artifact.txt"), atomically: true, encoding: .utf8)

    try FileManager.default.createDirectory(at: legacyBuild, withIntermediateDirectories: true)
    try "derived".write(to: legacyBuild.appendingPathComponent("BuildProduct"), atomically: true, encoding: .utf8)

    let defaults = testDefaults()
    let service = BuildCacheService(
      cacheRoot: cacheRoot,
      legacyBuilds: legacyBuilds,
      defaults: defaults,
      installsSwiftWrapper: false
    )

    let report = await service.prepareForLaunch(knownWorkspacePaths: [workspace.path])

    #expect(report.migratedXcodeSandboxes == 1)
    #expect(report.deletedLegacyBuildDirectories == 1)
    #expect(!FileManager.default.fileExists(atPath: legacyBuild.path))
    #expect(!FileManager.default.fileExists(atPath: module.appendingPathComponent(".build").path))
    #expect(FileManager.default.fileExists(
      atPath: cacheRoot
        .appendingPathComponent("Builds/\(BuildCachePaths.workspaceHash(for: workspace.path))/xcode/BuildProduct")
        .path
    ))
  }

  @Test func garbageCollectionDeletesOrphanedWorkspaceCacheEvenWhenPinned() async throws {
    let root = temporaryDirectory()
    let cacheRoot = root.appendingPathComponent("Caches/AgentHub", isDirectory: true)
    let missingWorkspace = root.appendingPathComponent("Missing", isDirectory: true)
    let workspaceID = BuildCachePaths.workspaceHash(for: missingWorkspace.path)
    let buildRoot = cacheRoot.appendingPathComponent("Builds/\(workspaceID)", isDirectory: true)

    try FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: true)
    try missingWorkspace.path.write(to: buildRoot.appendingPathComponent("workspace.path"), atomically: true, encoding: .utf8)
    try "cache".write(to: buildRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

    let defaults = testDefaults()
    defaults.set([workspaceID], forKey: AgentHubDefaults.buildCachePinnedWorkspaceIDs)
    let service = BuildCacheService(
      cacheRoot: cacheRoot,
      legacyBuilds: root.appendingPathComponent("Legacy", isDirectory: true),
      defaults: defaults,
      installsSwiftWrapper: false
    )

    let report = await service.runGarbageCollection(knownWorkspacePaths: [missingWorkspace.path])

    #expect(report.deletedCacheEntries == 1)
    #expect(!FileManager.default.fileExists(atPath: buildRoot.path))
  }

  @Test func storageSnapshotReportsPinnedEntriesAndTotalSize() async throws {
    let root = temporaryDirectory()
    let cacheRoot = root.appendingPathComponent("Caches/AgentHub", isDirectory: true)
    let workspace = root.appendingPathComponent("Project", isDirectory: true)
    let workspaceID = BuildCachePaths.workspaceHash(for: workspace.path)
    let buildRoot = cacheRoot.appendingPathComponent("Builds/\(workspaceID)", isDirectory: true)

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: true)
    try workspace.path.write(to: buildRoot.appendingPathComponent("workspace.path"), atomically: true, encoding: .utf8)
    try "cache".write(to: buildRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

    let defaults = testDefaults()
    defaults.set([workspaceID], forKey: AgentHubDefaults.buildCachePinnedWorkspaceIDs)
    let service = BuildCacheService(
      cacheRoot: cacheRoot,
      legacyBuilds: root.appendingPathComponent("Legacy", isDirectory: true),
      defaults: defaults,
      installsSwiftWrapper: false
    )

    let snapshot = await service.storageSnapshot(knownWorkspacePaths: [workspace.path])
    let entry = try #require(snapshot.workspaces.first)

    #expect(snapshot.totalSizeBytes > 0)
    #expect(entry.id == workspaceID)
    #expect(entry.workspacePath == workspace.path)
    #expect(entry.isPinned)
  }

  @Test func processEnvironmentPrependsWrapperAndExportsWorkspace() {
    let workspace = "/tmp/AgentHubWorkspace"
    let environment = AgentHubProcessEnvironment.environment(
      additionalPaths: ["/custom/bin"],
      workspacePath: workspace,
      base: ["PATH": "/usr/bin"],
      installWrapper: false
    )

    #expect(environment["AGENTHUB_CACHE_ROOT"] == BuildCachePaths.cacheRoot.path)
    #expect(environment["AGENTHUB_REAL_SWIFT"] == "/usr/bin/swift")
    #expect(environment["AGENTHUB_WORKSPACE_PATH"] == workspace)
    #expect(environment["PATH"]?.hasPrefix(BuildCachePaths.swiftWrapperBin.path + ":") == true)
    #expect(environment["PATH"]?.contains("/custom/bin") == true)
  }

  @Test func swiftWrapperInjectsScratchAndCachePaths() throws {
    let root = temporaryDirectory()
    let workspace = root.appendingPathComponent("Repo", isDirectory: true)
    let package = workspace.appendingPathComponent("app/modules/AgentHubCore", isDirectory: true)
    let cacheRoot = root.appendingPathComponent("CacheRoot", isDirectory: true)
    let wrapper = root.appendingPathComponent("swift", isDirectory: false)
    let fakeSwift = root.appendingPathComponent("fake-swift", isDirectory: false)
    let output = root.appendingPathComponent("args.txt", isDirectory: false)

    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try "package".write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try BuildCachePaths.swiftWrapperScript().write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    try """
    #!/bin/bash
    printf "%s\\n" "$@" > "\(output.path)"
    """.write(to: fakeSwift, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path)

    let process = Process()
    process.executableURL = wrapper
    process.arguments = ["build", "-c", "debug"]
    process.currentDirectoryURL = package
    process.environment = [
      "AGENTHUB_CACHE_ROOT": cacheRoot.path,
      "AGENTHUB_REAL_SWIFT": fakeSwift.path,
      "AGENTHUB_WORKSPACE_PATH": workspace.path,
      "PATH": "/usr/bin:/bin"
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    let args = try String(contentsOf: output, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
    #expect(Array(args.prefix(5)) == [
      "build",
      "--scratch-path",
      cacheRoot
        .appendingPathComponent("Builds/\(BuildCachePaths.workspaceHash(for: workspace.path))/swiftpm/\(BuildCachePaths.packageHash(for: package.path))")
        .path,
      "--cache-path",
      cacheRoot.appendingPathComponent("SwiftPMShared/package-cache").path
    ])
    #expect(args.contains("-c"))
    #expect(args.contains("debug"))
  }

  private func temporaryDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("BuildCacheServiceTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func testDefaults() -> UserDefaults {
    let suiteName = "BuildCacheServiceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
