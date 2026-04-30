import Foundation
import Testing
@testable import AgentHubCore

@Suite("BuildCacheService")
struct BuildCacheServiceTests {

  @Test func prepareForLaunchMigratesLegacyXcodeAndLeavesWorkspaceBuildsAlone() async throws {
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
      defaults: defaults
    )

    let report = await service.prepareForLaunch(knownWorkspacePaths: [workspace.path])

    #expect(report.migratedXcodeSandboxes == 1)
    #expect(!FileManager.default.fileExists(atPath: legacyBuild.path))
    #expect(FileManager.default.fileExists(atPath: module.appendingPathComponent(".build").path))
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
      defaults: defaults
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
      defaults: defaults
    )

    let snapshot = await service.storageSnapshot(knownWorkspacePaths: [workspace.path])
    let entry = try #require(snapshot.workspaces.first)

    #expect(snapshot.totalSizeBytes > 0)
    #expect(entry.id == workspaceID)
    #expect(entry.workspacePath == workspace.path)
    #expect(entry.isPinned)
  }

  @Test func processEnvironmentPreservesConfiguredPathsWithoutSwiftOverrides() {
    let environment = AgentHubProcessEnvironment.environment(
      additionalPaths: ["/custom/bin"],
      workspacePath: "/tmp/AgentHubWorkspace",
      base: ["PATH": "/usr/bin"]
    )

    #expect(environment["AGENTHUB_CACHE_ROOT"] == nil)
    #expect(environment["AGENTHUB_REAL_SWIFT"] == nil)
    #expect(environment["AGENTHUB_WORKSPACE_PATH"] == nil)
    #expect(environment["PATH"]?.hasPrefix("/custom/bin:") == true)
    #expect(environment["PATH"]?.contains("/custom/bin") == true)
    #expect(environment["PATH"]?.contains("/usr/bin") == true)
  }

  @Test func shellExportsDoNotShadowSwift() {
    let exports = AgentHubProcessEnvironment.shellExports(
      additionalPaths: ["/custom/bin"],
      workspacePath: "/tmp/AgentHubWorkspace"
    )

    #expect(exports.contains("export PATH="))
    #expect(exports.contains("/custom/bin"))
    #expect(!exports.contains("AGENTHUB_CACHE_ROOT"))
    #expect(!exports.contains("AGENTHUB_REAL_SWIFT"))
    #expect(!exports.contains("AGENTHUB_WORKSPACE_PATH"))
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
