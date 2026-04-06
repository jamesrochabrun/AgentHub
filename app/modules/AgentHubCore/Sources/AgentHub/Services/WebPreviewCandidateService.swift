//
//  WebPreviewCandidateService.swift
//  AgentHub
//
//  Fast, cached project-level classification for whether a repo is a web
//  preview candidate without relying on session message history.
//

import Foundation

public protocol WebPreviewCandidateServiceProtocol: Sendable {
  func cachedCandidateStatus(for projectPath: String) async -> WebPreviewCandidateStatus?
  func candidateStatus(for projectPath: String) async -> WebPreviewCandidateStatus
  func invalidate(projectPath: String) async
}

public enum WebPreviewCandidateReason: String, Sendable, Equatable {
  case knownFramework
  case likelyWebPackage
  case staticEntry
}

public enum WebPreviewCandidateStatus: Equatable, Sendable {
  case checking
  case candidate(reason: WebPreviewCandidateReason)
  case notCandidate

  var isCandidate: Bool {
    if case .candidate = self {
      return true
    }
    return false
  }

  var isChecking: Bool {
    if case .checking = self {
      return true
    }
    return false
  }
}

enum WebPreviewCandidateVisibility {
  static func shouldShow(
    candidateStatus: WebPreviewCandidateStatus?,
    detectedLocalhostURL: URL?
  ) -> Bool {
    if detectedLocalhostURL != nil {
      return true
    }

    return candidateStatus?.isCandidate == true
  }
}

public actor WebPreviewCandidateService: WebPreviewCandidateServiceProtocol {
  public static let shared = WebPreviewCandidateService()

  typealias Evaluator = @Sendable (String) async -> WebPreviewCandidateStatus

  private struct CacheEntry: Sendable {
    let status: WebPreviewCandidateStatus
    let expiresAt: Date?

    func isValid(at date: Date) -> Bool {
      guard let expiresAt else { return true }
      return expiresAt > date
    }
  }

  private struct PackageSignals: Sendable {
    let dependencyKeys: Set<String>
    let scriptKeys: Set<String>
    let scriptValues: [String: String]

    static let empty = PackageSignals(
      dependencyKeys: [],
      scriptKeys: [],
      scriptValues: [:]
    )
  }

  private static let knownFrameworkDependencies: Set<String> = [
    "vite",
    "next",
    "react-scripts",
    "@angular/core",
    "@vue/cli-service",
    "astro",
    "nuxt",
    "svelte",
    "@sveltejs/kit",
  ]

  private static let knownFrameworkConfigPaths: [String] = [
    "vite.config.js",
    "vite.config.mjs",
    "vite.config.cjs",
    "vite.config.ts",
    "vite.config.mts",
    "vite.config.cts",
    "next.config.js",
    "next.config.mjs",
    "next.config.ts",
    "astro.config.js",
    "astro.config.mjs",
    "astro.config.ts",
    "angular.json",
    "nuxt.config.js",
    "nuxt.config.mjs",
    "nuxt.config.ts",
    "svelte.config.js",
    "svelte.config.mjs",
    "svelte.config.cjs",
    "svelte.config.ts",
  ]

  private static let entryPointPaths: [String] = [
    "index.html",
    "public/index.html",
    "static/index.html",
    "src/index.html",
    "www/index.html",
    "dist/index.html",
    "build/index.html",
    "src/main.js",
    "src/main.ts",
    "src/main.jsx",
    "src/main.tsx",
    "app/page.js",
    "app/page.jsx",
    "app/page.ts",
    "app/page.tsx",
    "pages/index.js",
    "pages/index.jsx",
    "pages/index.ts",
    "pages/index.tsx",
  ]

  private static let skippedChildDirectoryNames: Set<String> = [
    ".git",
    ".svn",
    ".build",
    ".next",
    ".nuxt",
    ".cache",
    "node_modules",
    "dist",
    "build",
    "coverage",
    "DerivedData",
  ]

  private let negativeCacheTTL: TimeInterval
  private let now: @Sendable () -> Date
  private let evaluator: Evaluator

  private var cache: [String: CacheEntry] = [:]
  private var inFlightTasks: [String: Task<WebPreviewCandidateStatus, Never>] = [:]

  init(
    negativeCacheTTL: TimeInterval = 15,
    now: @escaping @Sendable () -> Date = { Date() },
    evaluator: Evaluator? = nil
  ) {
    self.negativeCacheTTL = negativeCacheTTL
    self.now = now
    self.evaluator = evaluator ?? { projectPath in
      await Self.defaultEvaluator(projectPath: projectPath)
    }
  }

  public func candidateStatus(for projectPath: String) async -> WebPreviewCandidateStatus {
    let normalizedProjectPath = Self.normalize(projectPath)
    let currentDate = now()

    if let cachedStatus = cachedCandidateStatus(
      forNormalizedProjectPath: normalizedProjectPath,
      at: currentDate
    ) {
      return cachedStatus
    }

    if let inFlightTask = inFlightTasks[normalizedProjectPath] {
      return await inFlightTask.value
    }

    let evaluator = self.evaluator
    let task = Task(priority: .utility) {
      await evaluator(normalizedProjectPath)
    }
    inFlightTasks[normalizedProjectPath] = task

    let status = await task.value
    inFlightTasks.removeValue(forKey: normalizedProjectPath)
    cache[normalizedProjectPath] = CacheEntry(
      status: status,
      expiresAt: expiration(for: status, from: currentDate)
    )
    return status
  }

  public func cachedCandidateStatus(for projectPath: String) async -> WebPreviewCandidateStatus? {
    cachedCandidateStatus(
      forNormalizedProjectPath: Self.normalize(projectPath),
      at: now()
    )
  }

  public func invalidate(projectPath: String) async {
    let normalizedProjectPath = Self.normalize(projectPath)
    cache.removeValue(forKey: normalizedProjectPath)
    inFlightTasks[normalizedProjectPath]?.cancel()
    inFlightTasks.removeValue(forKey: normalizedProjectPath)
  }

  private func expiration(for status: WebPreviewCandidateStatus, from date: Date) -> Date? {
    switch status {
    case .candidate:
      return nil
    case .checking:
      return date
    case .notCandidate:
      return date.addingTimeInterval(negativeCacheTTL)
    }
  }

  private func cachedCandidateStatus(
    forNormalizedProjectPath normalizedProjectPath: String,
    at date: Date
  ) -> WebPreviewCandidateStatus? {
    guard let cacheEntry = cache[normalizedProjectPath] else {
      return nil
    }

    guard cacheEntry.isValid(at: date) else {
      cache.removeValue(forKey: normalizedProjectPath)
      return nil
    }

    return cacheEntry.status
  }

  private nonisolated static func defaultEvaluator(projectPath: String) async -> WebPreviewCandidateStatus {
    await Task.detached(priority: .utility) {
      evaluateSynchronously(projectPath: projectPath)
    }.value
  }

  private nonisolated static func evaluateSynchronously(projectPath: String) -> WebPreviewCandidateStatus {
    for candidateProjectPath in candidateProjectPaths(rootProjectPath: projectPath) {
      let packageSignals = loadPackageSignals(projectPath: candidateProjectPath)

      if hasKnownFrameworkSignal(projectPath: candidateProjectPath, packageSignals: packageSignals) {
        return .candidate(reason: .knownFramework)
      }

      if hasLikelyWebPackageSignal(packageSignals: packageSignals) {
        return .candidate(reason: .likelyWebPackage)
      }

      if hasStaticEntrySignal(projectPath: candidateProjectPath) {
        return .candidate(reason: .staticEntry)
      }
    }

    return .notCandidate
  }

  private nonisolated static func hasKnownFrameworkSignal(
    projectPath: String,
    packageSignals: PackageSignals
  ) -> Bool {
    if !knownFrameworkDependencies.isDisjoint(with: packageSignals.dependencyKeys) {
      return true
    }

    if packageSignals.scriptValues.values.contains(where: { scriptValue in
      let normalized = scriptValue.lowercased()
      return normalized.contains("vite")
        || normalized.contains("next")
        || normalized.contains("astro")
        || normalized.contains("nuxt")
        || normalized.contains("ng serve")
        || normalized.contains("vue-cli-service")
        || normalized.contains("svelte-kit")
    }) {
      return true
    }

    return knownFrameworkConfigPaths.contains { relativePath in
      FileManager.default.fileExists(atPath: projectPath + "/" + relativePath)
    }
  }

  private nonisolated static func hasLikelyWebPackageSignal(packageSignals: PackageSignals) -> Bool {
    let likelyScriptNames: Set<String> = ["dev", "start", "serve", "preview"]
    return !likelyScriptNames.isDisjoint(with: packageSignals.scriptKeys)
  }

  private nonisolated static func hasStaticEntrySignal(projectPath: String) -> Bool {
    entryPointPaths.contains { relativePath in
      FileManager.default.fileExists(atPath: projectPath + "/" + relativePath)
    }
  }

  private nonisolated static func loadPackageSignals(projectPath: String) -> PackageSignals {
    let packageJsonPath = projectPath + "/package.json"
    guard let data = FileManager.default.contents(atPath: packageJsonPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .empty
    }

    let dependencies = json["dependencies"] as? [String: Any] ?? [:]
    let devDependencies = json["devDependencies"] as? [String: Any] ?? [:]
    let dependencyKeys = Set(
      dependencies.keys.map { $0.lowercased() }
        + devDependencies.keys.map { $0.lowercased() }
    )

    let scripts = json["scripts"] as? [String: String] ?? [:]
    let normalizedScripts = Dictionary(
      uniqueKeysWithValues: scripts.map { ($0.key.lowercased(), $0.value) }
    )

    return PackageSignals(
      dependencyKeys: dependencyKeys,
      scriptKeys: Set(normalizedScripts.keys),
      scriptValues: normalizedScripts
    )
  }

  private nonisolated static func candidateProjectPaths(rootProjectPath: String) -> [String] {
    var paths = [rootProjectPath]

    let rootURL = URL(fileURLWithPath: rootProjectPath)
    let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]

    guard let childURLs = try? FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles]
    ) else {
      return paths
    }

    let childDirectories = childURLs
      .filter { url in
        guard skippedChildDirectoryNames.contains(url.lastPathComponent) == false else {
          return false
        }

        let isDirectory = (try? url.resourceValues(forKeys: resourceKeys).isDirectory) ?? false
        return isDirectory
      }
      .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      .map(\.path)

    paths.append(contentsOf: childDirectories)
    return paths
  }

  nonisolated static func normalize(_ projectPath: String) -> String {
    URL(fileURLWithPath: projectPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
  }
}
