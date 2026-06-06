//
//  CodexModelCatalog.swift
//  AgentHub
//
//  Dynamically resolves the list of available Codex models by invoking
//  `codex debug models`, falling back to the on-disk model cache. This avoids
//  hardcoding model slugs, which change with every Codex release.
//

import Foundation

// MARK: - Protocols

/// Runs `codex debug models` and returns the raw JSON payload.
public protocol CodexDebugModelsCommandRunning: Sendable {
  func debugModelsJSON(homeDirectory: String) async throws -> Data
}

/// Provides the set of selectable Codex models and the configured default.
public protocol CodexModelCatalogProviding: Sendable {
  /// Live `codex debug models` output, falling back to the on-disk cache.
  func availableModels() async -> [AIModelOption]
  /// The model id Codex would use by default (`config.toml` → first cached → fallback).
  func defaultModelIdentifier() async -> String
}

// MARK: - Catalog

public struct CodexModelCatalog: CodexModelCatalogProviding {
  /// Used only when neither the live command, the cache, nor config.toml yields anything.
  static let fallbackModelIdentifier = "gpt-5-codex"

  private let commandRunner: any CodexDebugModelsCommandRunning
  private let homeDirectory: String

  public init() {
    self.init(commandRunner: CodexDebugModelsCommandRunner())
  }

  init(
    commandRunner: any CodexDebugModelsCommandRunning,
    homeDirectory: String = NSHomeDirectory()
  ) {
    self.commandRunner = commandRunner
    self.homeDirectory = homeDirectory
  }

  public func availableModels() async -> [AIModelOption] {
    if let data = try? await commandRunner.debugModelsJSON(homeDirectory: homeDirectory),
       let models = try? Self.modelOptions(fromDebugModelsJSON: data),
       !models.isEmpty {
      return models
    }
    return cachedModels()
  }

  public func defaultModelIdentifier() async -> String {
    if let configured = configuredModelIdentifier() {
      return configured
    }
    if let firstCached = cachedModels().first?.identifier {
      return firstCached
    }
    return Self.fallbackModelIdentifier
  }

  // MARK: - Cache + config (disk)

  func cachedModels() -> [AIModelOption] {
    let cacheURL = URL(fileURLWithPath: homeDirectory)
      .appendingPathComponent(".codex/models_cache.json")
    guard let data = try? Data(contentsOf: cacheURL) else { return [] }
    return (try? Self.modelOptions(fromDebugModelsJSON: data)) ?? []
  }

  func configuredModelIdentifier() -> String? {
    let configURL = URL(fileURLWithPath: homeDirectory)
      .appendingPathComponent(".codex/config.toml")
    guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
    return Self.configuredModelIdentifier(inConfigTOML: contents)
  }

  // MARK: - Parsing (pure, testable)

  /// Decodes a `codex debug models` / `models_cache.json` payload into options,
  /// keeping only listable models and ordering them by Codex's own priority.
  static func modelOptions(fromDebugModelsJSON data: Data) throws -> [AIModelOption] {
    let payload = try JSONDecoder().decode(ModelCachePayload.self, from: data)
    return payload.models
      .filter { ($0.visibility ?? "list") == "list" }
      .sorted { lhs, rhs in
        let lhsPriority = lhs.priority ?? Int.max
        let rhsPriority = rhs.priority ?? Int.max
        if lhsPriority != rhsPriority {
          return lhsPriority < rhsPriority
        }
        return (lhs.displayName ?? lhs.slug)
          .localizedStandardCompare(rhs.displayName ?? rhs.slug) == .orderedAscending
      }
      .map { model in
        let trimmedName = model.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (trimmedName?.isEmpty == false) ? trimmedName! : model.slug
        let trimmedDetail = model.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let efforts = (model.supportedReasoningLevels ?? []).map { level -> AIReasoningEffort in
          let levelDetail = level.description?.trimmingCharacters(in: .whitespacesAndNewlines)
          return AIReasoningEffort(
            effort: level.effort,
            description: (levelDetail?.isEmpty == false) ? levelDetail : nil
          )
        }
        return AIModelOption(
          identifier: model.slug,
          displayName: displayName,
          detail: (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil,
          reasoningEfforts: efforts,
          defaultReasoningEffort: model.defaultReasoningLevel
        )
      }
  }

  /// Extracts the top-level `model = "…"` value from a Codex `config.toml`.
  /// Stops at the first table header so only the root `model` key is honored.
  static func configuredModelIdentifier(inConfigTOML contents: String) -> String? {
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let line = lineWithoutComment(String(rawLine))
        .trimmingCharacters(in: .whitespacesAndNewlines)

      if line.hasPrefix("[") {
        return nil
      }

      guard let (key, value) = keyValuePair(from: line), key == "model" else {
        continue
      }

      return value.isEmpty ? nil : value
    }
    return nil
  }

  private static func keyValuePair(from line: String) -> (key: String, value: String)? {
    let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = parts[1]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

    return (key, value)
  }

  private static func lineWithoutComment(_ line: String) -> String {
    guard let commentStart = line.firstIndex(of: "#") else { return line }
    return String(line[..<commentStart])
  }

  private struct ModelCachePayload: Decodable {
    let models: [CachedModel]
  }

  private struct CachedModel: Decodable {
    let slug: String
    let displayName: String?
    let description: String?
    let visibility: String?
    let priority: Int?
    let supportedReasoningLevels: [ReasoningLevel]?
    let defaultReasoningLevel: String?

    private enum CodingKeys: String, CodingKey {
      case slug
      case displayName = "display_name"
      case description
      case visibility
      case priority
      case supportedReasoningLevels = "supported_reasoning_levels"
      case defaultReasoningLevel = "default_reasoning_level"
    }
  }

  private struct ReasoningLevel: Decodable {
    let effort: String
    let description: String?
  }
}

// MARK: - Command runner

/// Runs `codex debug models`, preferring a local Codex install and reusing the
/// app's executable resolution and PATH building.
public struct CodexDebugModelsCommandRunner: CodexDebugModelsCommandRunning {
  public init() {}

  public func debugModelsJSON(homeDirectory: String) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      try Self.run(homeDirectory: homeDirectory)
    }.value
  }

  private static func run(homeDirectory: String) throws -> Data {
    let invocation = codexInvocation(homeDirectory: homeDirectory)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: invocation.executablePath)
    process.arguments = invocation.arguments
    process.environment = environment(homeDirectory: homeDirectory)

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()

    // Drain stdout before waiting: `codex debug models` emits ~170 KB, which
    // exceeds the pipe buffer and would deadlock a wait-then-read ordering.
    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let message = String(data: errorData, encoding: .utf8) ?? "codex debug models failed"
      throw CodexDebugModelsCommandError.nonZeroExit(message)
    }

    return output
  }

  private static func codexInvocation(
    homeDirectory: String
  ) -> (executablePath: String, arguments: [String]) {
    let arguments = ["debug", "models"]

    let localCodexPath = "\(homeDirectory)/.codex/local/codex"
    if FileManager.default.isExecutableFile(atPath: localCodexPath) {
      return (localCodexPath, arguments)
    }

    if let detected = TerminalLauncher.findCodexExecutable(additionalPaths: nil) {
      return (detected, arguments)
    }

    return ("/usr/bin/env", ["codex"] + arguments)
  }

  private static func environment(homeDirectory: String) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = homeDirectory
    environment["CODEX_HOME"] = URL(fileURLWithPath: homeDirectory)
      .appendingPathComponent(".codex")
      .path

    let resolverPaths = CLIPathResolver.codexPaths(additionalPaths: [], homeDirectory: homeDirectory)
    if let currentPath = environment["PATH"], !currentPath.isEmpty {
      environment["PATH"] = (resolverPaths + [currentPath]).joined(separator: ":")
    } else {
      environment["PATH"] = resolverPaths.joined(separator: ":")
    }

    return environment
  }
}

enum CodexDebugModelsCommandError: LocalizedError {
  case nonZeroExit(String)

  var errorDescription: String? {
    switch self {
    case .nonZeroExit(let message):
      return message
    }
  }
}
