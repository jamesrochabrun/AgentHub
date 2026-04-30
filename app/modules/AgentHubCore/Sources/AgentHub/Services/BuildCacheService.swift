//
//  BuildCacheService.swift
//  AgentHub
//

import CryptoKit
import Foundation

// MARK: - Build Cache Models

public struct BuildCacheWorkspaceSummary: Identifiable, Sendable, Equatable {
  public let id: String
  public let workspacePath: String?
  public let sizeBytes: Int64
  public let lastAccessed: Date?
  public let isPinned: Bool

  public var displayPath: String {
    workspacePath ?? id
  }

  public var existsOnDisk: Bool {
    guard let workspacePath else { return false }
    return FileManager.default.fileExists(atPath: workspacePath)
  }
}

public struct BuildCacheStorageSnapshot: Sendable, Equatable {
  public let cacheRootPath: String
  public let totalSizeBytes: Int64
  public let workspaces: [BuildCacheWorkspaceSummary]

  public static let empty = BuildCacheStorageSnapshot(
    cacheRootPath: BuildCachePaths.cacheRoot.path,
    totalSizeBytes: 0,
    workspaces: []
  )
}

public struct BuildCacheCleanupReport: Sendable, Equatable {
  public var migratedXcodeSandboxes: Int = 0
  public var deletedCacheEntries: Int = 0
  public var deletedBytes: Int64 = 0

  public var didMigrateOrCleanLegacyCaches: Bool {
    migratedXcodeSandboxes > 0
  }
}

public struct BuildCacheXcodePaths: Sendable, Equatable {
  public let workspaceHash: String
  public let derivedDataPath: String
  public let clonedSourcePackagesPath: String
  public let packageCachePath: String
}

// MARK: - BuildCachePaths

public enum BuildCachePaths {
  public static var cacheRoot: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appendingPathComponent("AgentHub", isDirectory: true)
  }

  public static var legacyApplicationSupportBuilds: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("AgentHub", isDirectory: true)
      .appendingPathComponent("Builds", isDirectory: true)
  }

  public static var buildsRoot: URL {
    cacheRoot.appendingPathComponent("Builds", isDirectory: true)
  }

  public static var swiftPMSharedRoot: URL {
    cacheRoot.appendingPathComponent("SwiftPMShared", isDirectory: true)
  }

  public static var packageCachePath: URL {
    swiftPMSharedRoot.appendingPathComponent("package-cache", isDirectory: true)
  }

  public static var clonedSourcePackagesPath: URL {
    swiftPMSharedRoot.appendingPathComponent("source-packages", isDirectory: true)
  }

  public static func workspaceHash(for workspacePath: String) -> String {
    SHA256.hash(data: Data(workspacePath.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  public static func buildRoot(for workspacePath: String) -> URL {
    buildsRoot.appendingPathComponent(workspaceHash(for: workspacePath), isDirectory: true)
  }

  public static func xcodePaths(for workspacePath: String) -> BuildCacheXcodePaths {
    let workspaceHash = workspaceHash(for: workspacePath)
    let buildRoot = buildsRoot.appendingPathComponent(workspaceHash, isDirectory: true)
    return BuildCacheXcodePaths(
      workspaceHash: workspaceHash,
      derivedDataPath: buildRoot.appendingPathComponent("xcode", isDirectory: true).path,
      clonedSourcePackagesPath: clonedSourcePackagesPath.path,
      packageCachePath: packageCachePath.path
    )
  }

  public static func recordWorkspacePath(_ workspacePath: String) {
    let buildRoot = buildRoot(for: workspacePath)
    do {
      try FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: true)
      try workspacePath.write(
        to: buildRoot.appendingPathComponent("workspace.path"),
        atomically: true,
        encoding: .utf8
      )
    } catch {
      AppLogger.buildCache.error("Failed to record workspace path: \(error.localizedDescription)")
    }
  }
}

// MARK: - Process Environment

public enum AgentHubProcessEnvironment {
  public static func environment(
    additionalPaths: [String],
    workspacePath _: String?,
    base: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = base
    environment["TERM"] = environment["TERM"] ?? "xterm-256color"
    environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
    environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
    environment.removeValue(forKey: "TERM_PROGRAM")

    let paths = CLIPathResolver.executableSearchPaths(additionalPaths: additionalPaths)
    let pathString = paths.joined(separator: ":")
    if let existingPath = environment["PATH"] {
      environment["PATH"] = "\(pathString):\(existingPath)"
    } else {
      environment["PATH"] = pathString
    }
    return environment
  }

  public static func shellExports(
    additionalPaths: [String],
    workspacePath _: String?
  ) -> String {
    let paths = CLIPathResolver.executableSearchPaths(additionalPaths: additionalPaths)
    return "export PATH=\(shellQuote(paths.joined(separator: ":"))):\"$PATH\""
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

// MARK: - BuildCacheServiceProtocol

public protocol BuildCacheServiceProtocol: Sendable {
  func prepareForLaunch(knownWorkspacePaths: [String]) async -> BuildCacheCleanupReport
  func runGarbageCollection(knownWorkspacePaths: [String]) async -> BuildCacheCleanupReport
  func storageSnapshot(knownWorkspacePaths: [String]) async -> BuildCacheStorageSnapshot
  func setPinned(_ isPinned: Bool, forWorkspaceID id: String) async
  func deleteWorkspaceCache(id: String) async throws
  func clearAllCaches() async throws
}

// MARK: - BuildCacheService

public actor BuildCacheService: BuildCacheServiceProtocol {
  private let fileManager: FileManager
  private let cacheRoot: URL
  private let legacyBuilds: URL
  private let defaults: UserDefaults

  public init(
    cacheRoot: URL = BuildCachePaths.cacheRoot,
    legacyBuilds: URL = BuildCachePaths.legacyApplicationSupportBuilds,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) {
    self.cacheRoot = cacheRoot
    self.legacyBuilds = legacyBuilds
    self.defaults = defaults
    self.fileManager = fileManager
  }

  public func prepareForLaunch(knownWorkspacePaths: [String]) async -> BuildCacheCleanupReport {
    var report = BuildCacheCleanupReport()
    if !defaults.bool(forKey: AgentHubDefaults.buildCacheMigrationCompleted) {
      report = migrateLegacyXcodeBuilds()
      defaults.set(true, forKey: AgentHubDefaults.buildCacheMigrationCompleted)
    }
    let gcReport = await runGarbageCollection(knownWorkspacePaths: knownWorkspacePaths)
    report.deletedCacheEntries += gcReport.deletedCacheEntries
    report.deletedBytes += gcReport.deletedBytes
    return report
  }

  public func runGarbageCollection(knownWorkspacePaths: [String]) async -> BuildCacheCleanupReport {
    var report = BuildCacheCleanupReport()
    let snapshot = await storageSnapshot(knownWorkspacePaths: knownWorkspacePaths)
    let pinned = pinnedWorkspaceIDs()

    for entry in snapshot.workspaces where !entry.existsOnDisk {
      let url = buildsDirectory().appendingPathComponent(entry.id, isDirectory: true)
      if removeItemIfExists(at: url) {
        report.deletedBytes += entry.sizeBytes
        report.deletedCacheEntries += 1
      }
    }

    let refreshed = await storageSnapshot(knownWorkspacePaths: knownWorkspacePaths)
    var total = refreshed.totalSizeBytes
    let cap = cacheSizeLimitBytes()
    guard total > cap else { return report }

    let minimumAge: TimeInterval = 24 * 60 * 60
    let candidates = refreshed.workspaces
      .filter { !pinned.contains($0.id) }
      .filter { entry in
        guard let lastAccessed = entry.lastAccessed else { return true }
        return Date().timeIntervalSince(lastAccessed) >= minimumAge
      }
      .sorted {
        ($0.lastAccessed ?? .distantPast) < ($1.lastAccessed ?? .distantPast)
      }

    for entry in candidates where total > cap {
      let url = buildsDirectory().appendingPathComponent(entry.id, isDirectory: true)
      if removeItemIfExists(at: url) {
        total -= entry.sizeBytes
        report.deletedBytes += entry.sizeBytes
        report.deletedCacheEntries += 1
      }
    }

    return report
  }

  public func storageSnapshot(knownWorkspacePaths: [String]) async -> BuildCacheStorageSnapshot {
    let known = Set(await expandedWorkspacePaths(from: knownWorkspacePaths))
    let pinned = pinnedWorkspaceIDs()
    let builds = buildsDirectory()
    guard let entries = try? fileManager.contentsOfDirectory(
      at: builds,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return BuildCacheStorageSnapshot(
        cacheRootPath: cacheRoot.path,
        totalSizeBytes: directorySize(cacheRoot),
        workspaces: []
      )
    }

    var summaries: [BuildCacheWorkspaceSummary] = []
    var buildsSizeBytes: Int64 = 0
    for entry in entries {
      guard isDirectory(entry) else { continue }
      let id = entry.lastPathComponent
      let sizeBytes = directorySize(entry)
      buildsSizeBytes += sizeBytes
      let workspacePath = workspacePath(forBuildRoot: entry, knownWorkspacePaths: known)
      summaries.append(BuildCacheWorkspaceSummary(
        id: id,
        workspacePath: workspacePath,
        sizeBytes: sizeBytes,
        lastAccessed: lastAccessedDate(forBuildRoot: entry),
        isPinned: pinned.contains(id)
      ))
    }

    summaries.sort {
      if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
      return $0.displayPath < $1.displayPath
    }

    return BuildCacheStorageSnapshot(
      cacheRootPath: cacheRoot.path,
      totalSizeBytes: cacheRootSize(buildsSizeBytes: buildsSizeBytes),
      workspaces: summaries
    )
  }

  public func setPinned(_ isPinned: Bool, forWorkspaceID id: String) async {
    var pinned = pinnedWorkspaceIDs()
    if isPinned {
      pinned.insert(id)
    } else {
      pinned.remove(id)
    }
    defaults.set(Array(pinned).sorted(), forKey: AgentHubDefaults.buildCachePinnedWorkspaceIDs)
  }

  public func deleteWorkspaceCache(id: String) async throws {
    let url = buildsDirectory().appendingPathComponent(id, isDirectory: true)
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
  }

  public func clearAllCaches() async throws {
    let builds = buildsDirectory()
    let shared = cacheRoot.appendingPathComponent("SwiftPMShared", isDirectory: true)
    if fileManager.fileExists(atPath: builds.path) {
      try fileManager.removeItem(at: builds)
    }
    if fileManager.fileExists(atPath: shared.path) {
      try fileManager.removeItem(at: shared)
    }
  }

  private func migrateLegacyXcodeBuilds() -> BuildCacheCleanupReport {
    var report = BuildCacheCleanupReport()
    guard let legacyEntries = try? fileManager.contentsOfDirectory(
      at: legacyBuilds,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return report
    }

    for legacyEntry in legacyEntries where isDirectory(legacyEntry) {
      let destination = buildsDirectory()
        .appendingPathComponent(legacyEntry.lastPathComponent, isDirectory: true)
        .appendingPathComponent("xcode", isDirectory: true)

      do {
        if fileManager.fileExists(atPath: destination.path) {
          try fileManager.removeItem(at: legacyEntry)
        } else {
          try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
          try fileManager.moveItem(at: legacyEntry, to: destination)
          report.migratedXcodeSandboxes += 1
        }
      } catch {
        AppLogger.buildCache.error("Failed to migrate build cache \(legacyEntry.path, privacy: .public): \(error.localizedDescription)")
      }
    }

    if let remaining = try? fileManager.contentsOfDirectory(atPath: legacyBuilds.path), remaining.isEmpty {
      try? fileManager.removeItem(at: legacyBuilds)
    }
    return report
  }

  private func expandedWorkspacePaths(from paths: [String]) async -> [String] {
    var result = Set(paths.filter { !$0.isEmpty })

    for path in paths where fileManager.fileExists(atPath: path) {
      let worktrees = await GitWorktreeDetector.listWorktrees(at: path)
      for worktree in worktrees {
        result.insert(worktree.path)
      }

      let nestedWorktrees = URL(fileURLWithPath: path, isDirectory: true)
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("worktrees", isDirectory: true)
      if let nested = try? fileManager.contentsOfDirectory(
        at: nestedWorktrees,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) {
        for candidate in nested where isDirectory(candidate) {
          result.insert(candidate.path)
        }
      }
    }

    return Array(result).sorted()
  }

  private func workspacePath(forBuildRoot url: URL, knownWorkspacePaths: Set<String>) -> String? {
    let manifest = url.appendingPathComponent("workspace.path", isDirectory: false)
    if let contents = try? String(contentsOf: manifest, encoding: .utf8) {
      let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }

    let xcodeInfo = url
      .appendingPathComponent("xcode", isDirectory: true)
      .appendingPathComponent("info.plist", isDirectory: false)
    if let plist = NSDictionary(contentsOf: xcodeInfo) as? [String: Any],
       let path = plist["WorkspacePath"] as? String {
      return path
    }

    return knownWorkspacePaths.first { BuildCachePaths.workspaceHash(for: $0) == url.lastPathComponent }
  }

  private func lastAccessedDate(forBuildRoot url: URL) -> Date? {
    let xcodeInfo = url
      .appendingPathComponent("xcode", isDirectory: true)
      .appendingPathComponent("info.plist", isDirectory: false)
    if let plist = NSDictionary(contentsOf: xcodeInfo) as? [String: Any],
       let date = plist["LastAccessedDate"] as? Date {
      return date
    }
    return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
  }

  private func pinnedWorkspaceIDs() -> Set<String> {
    Set(defaults.stringArray(forKey: AgentHubDefaults.buildCachePinnedWorkspaceIDs) ?? [])
  }

  private func cacheSizeLimitBytes() -> Int64 {
    let configured = defaults.integer(forKey: AgentHubDefaults.buildCacheSizeLimitGB)
    let gb = configured > 0 ? configured : 10
    return Int64(gb) * 1_000_000_000
  }

  private func buildsDirectory() -> URL {
    cacheRoot.appendingPathComponent("Builds", isDirectory: true)
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private func removeItemIfExists(at url: URL) -> Bool {
    guard fileManager.fileExists(atPath: url.path) else { return false }
    do {
      try fileManager.removeItem(at: url)
      return true
    } catch {
      AppLogger.buildCache.error("Failed to remove cache \(url.path, privacy: .public): \(error.localizedDescription)")
      return false
    }
  }

  private func cacheRootSize(buildsSizeBytes: Int64) -> Int64 {
    guard let entries = try? fileManager.contentsOfDirectory(
      at: cacheRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: []
    ) else {
      return buildsSizeBytes
    }

    let buildsPath = buildsDirectory().standardizedFileURL.path
    return entries.reduce(Int64(0)) { total, entry in
      if entry.standardizedFileURL.path == buildsPath {
        return total + buildsSizeBytes
      }
      return total + directorySize(entry)
    }
  }

  private func directorySize(_ url: URL) -> Int64 {
    guard fileManager.fileExists(atPath: url.path) else { return 0 }
    guard let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: []
    ) else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values?.isRegularFile == true {
        total += Int64(values?.fileSize ?? 0)
      }
    }
    return total
  }
}
