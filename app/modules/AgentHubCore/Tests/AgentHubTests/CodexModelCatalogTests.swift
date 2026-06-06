//
//  CodexModelCatalogTests.swift
//  AgentHub
//
//  Tests dynamic Codex model resolution: parsing `codex debug models` output,
//  cache fallback, and reading the configured default from config.toml.
//

import Foundation
import Testing
@testable import AgentHubCore

@Suite("CodexModelCatalog")
struct CodexModelCatalogTests {

  // MARK: - Parsing

  @Test("Keeps only listable models and orders them by priority")
  func parsesAndSortsListableModels() throws {
    let json = Data("""
    {"models":[
      {"slug":"gpt-5.4","display_name":"GPT-5.4","description":"Balanced","visibility":"list","priority":16},
      {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","priority":43},
      {"slug":"gpt-5.5","display_name":"GPT-5.5","description":"Frontier model","visibility":"list","priority":9}
    ]}
    """.utf8)

    let options = try CodexModelCatalog.modelOptions(fromDebugModelsJSON: json)

    #expect(options.map(\.identifier) == ["gpt-5.5", "gpt-5.4"])
    #expect(options.first?.displayName == "GPT-5.5")
    #expect(options.first?.detail == "Frontier model")
  }

  @Test("Falls back to the slug when display name is missing or blank")
  func displayNameFallsBackToSlug() throws {
    let json = Data("""
    {"models":[{"slug":"gpt-5.3-codex-spark","display_name":"   ","visibility":"list","priority":1}]}
    """.utf8)

    let options = try CodexModelCatalog.modelOptions(fromDebugModelsJSON: json)

    #expect(options.count == 1)
    #expect(options[0].displayName == "gpt-5.3-codex-spark")
    #expect(options[0].detail == nil)
  }

  @Test("Models without explicit visibility are treated as listable")
  func missingVisibilityIsListed() throws {
    let json = Data(#"{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5","priority":9}]}"#.utf8)

    let options = try CodexModelCatalog.modelOptions(fromDebugModelsJSON: json)

    #expect(options.map(\.identifier) == ["gpt-5.5"])
  }

  @Test("Parses per-model reasoning levels and the default")
  func parsesReasoningLevels() throws {
    let json = Data("""
    {"models":[{
      "slug":"gpt-5.3-codex-spark","display_name":"GPT-5.3-Codex-Spark","visibility":"list","priority":1,
      "default_reasoning_level":"high",
      "supported_reasoning_levels":[
        {"effort":"low","description":"Fast responses with lighter reasoning"},
        {"effort":"high","description":"Greater reasoning depth for complex problems"}
      ]
    }]}
    """.utf8)

    let options = try CodexModelCatalog.modelOptions(fromDebugModelsJSON: json)

    #expect(options.count == 1)
    #expect(options[0].defaultReasoningEffort == "high")
    #expect(options[0].reasoningEfforts.map(\.effort) == ["low", "high"])
    #expect(options[0].reasoningEfforts.first?.description == "Fast responses with lighter reasoning")
  }

  @Test("Reasoning levels are empty when the payload omits them")
  func reasoningLevelsDefaultEmpty() throws {
    let json = Data(#"{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","priority":9}]}"#.utf8)

    let options = try CodexModelCatalog.modelOptions(fromDebugModelsJSON: json)

    #expect(options[0].reasoningEfforts.isEmpty)
    #expect(options[0].defaultReasoningEffort == nil)
  }

  // MARK: - config.toml

  @Test("Reads the root model key, stripping quotes and comments")
  func readsConfiguredModelFromTOML() {
    let toml = """
    # Codex configuration
    model = "gpt-5.4-mini"  # preferred model
    approval_policy = "on-request"
    """

    #expect(CodexModelCatalog.configuredModelIdentifier(inConfigTOML: toml) == "gpt-5.4-mini")
  }

  @Test("Ignores model keys nested under a table header")
  func ignoresModelKeyInsideTable() {
    let toml = """
    approval_policy = "never"

    [profiles.work]
    model = "gpt-5.5"
    """

    #expect(CodexModelCatalog.configuredModelIdentifier(inConfigTOML: toml) == nil)
  }

  @Test("Returns nil when no model key is present")
  func returnsNilWhenModelMissing() {
    #expect(CodexModelCatalog.configuredModelIdentifier(inConfigTOML: "approval_policy = \"never\"") == nil)
  }

  // MARK: - Catalog behavior

  @Test("availableModels uses live command output when it succeeds")
  func availableModelsUsesLiveOutput() async {
    let json = Data(#"{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","priority":9}]}"#.utf8)
    let catalog = CodexModelCatalog(
      commandRunner: StubCommandRunner(result: .success(json)),
      homeDirectory: NSHomeDirectory()
    )

    let options = await catalog.availableModels()

    #expect(options.map(\.identifier) == ["gpt-5.5"])
  }

  @Test("availableModels falls back to the on-disk cache when the command fails")
  func availableModelsFallsBackToCache() async throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    let cache = Data(#"{"models":[{"slug":"gpt-5.4","display_name":"GPT-5.4","visibility":"list","priority":16}]}"#.utf8)
    try writeCodexFile(cache, named: "models_cache.json", inHome: home)

    let catalog = CodexModelCatalog(
      commandRunner: StubCommandRunner(result: .failure(SampleError.boom)),
      homeDirectory: home
    )

    let options = await catalog.availableModels()

    #expect(options.map(\.identifier) == ["gpt-5.4"])
  }

  @Test("defaultModelIdentifier prefers config.toml, then cache, then fallback")
  func defaultModelResolution() async throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }

    let catalog = CodexModelCatalog(
      commandRunner: StubCommandRunner(result: .failure(SampleError.boom)),
      homeDirectory: home
    )

    // No config, no cache → fallback.
    let fallback = await catalog.defaultModelIdentifier()
    #expect(fallback == CodexModelCatalog.fallbackModelIdentifier)

    // Cache present, still no config → first cached model.
    let cache = Data(#"{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5","visibility":"list","priority":9}]}"#.utf8)
    try writeCodexFile(cache, named: "models_cache.json", inHome: home)
    let cached = await catalog.defaultModelIdentifier()
    #expect(cached == "gpt-5.5")

    // config.toml wins over the cache.
    try writeCodexFile(Data("model = \"gpt-5.4\"\n".utf8), named: "config.toml", inHome: home)
    let configured = await catalog.defaultModelIdentifier()
    #expect(configured == "gpt-5.4")
  }

  // MARK: - Helpers

  private func makeTempHome() throws -> String {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex_catalog_\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".codex"),
      withIntermediateDirectories: true
    )
    return home.path
  }

  private func writeCodexFile(_ data: Data, named name: String, inHome home: String) throws {
    let url = URL(fileURLWithPath: home).appendingPathComponent(".codex").appendingPathComponent(name)
    try data.write(to: url)
  }
}

private struct StubCommandRunner: CodexDebugModelsCommandRunning {
  let result: Result<Data, Error>

  func debugModelsJSON(homeDirectory: String) async throws -> Data {
    try result.get()
  }
}

private enum SampleError: Error {
  case boom
}
