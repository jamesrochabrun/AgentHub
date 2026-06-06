//
//  ClaudeModelCatalogTests.swift
//  AgentHub
//
//  Tests local discovery of versioned Claude model ids from session JSONL plus
//  the stable aliases, with no hardcoded version list.
//

import Foundation
import Testing
@testable import AgentHubCore

@Suite("ClaudeModelCatalog")
struct ClaudeModelCatalogTests {

  // MARK: - Identifier validation

  @Test("Accepts versioned Claude ids and rejects noise")
  func validatesModelIdentifiers() {
    #expect(ClaudeModelCatalog.isValidModelIdentifier("claude-opus-4-8"))
    #expect(ClaudeModelCatalog.isValidModelIdentifier("claude-haiku-4-5-20251001"))

    // Display name (spaces + uppercase), beta-context suffix, and non-Claude ids.
    #expect(!ClaudeModelCatalog.isValidModelIdentifier("Claude Opus 4.8"))
    #expect(!ClaudeModelCatalog.isValidModelIdentifier("claude-opus-4-8[1m]"))
    #expect(!ClaudeModelCatalog.isValidModelIdentifier("gpt-5.5"))
    #expect(!ClaudeModelCatalog.isValidModelIdentifier("opus"))
  }

  // MARK: - Line + document extraction

  @Test("Extracts every model value from a line")
  func extractsModelValuesFromLine() {
    let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","other":"x"},"model":"claude-haiku-4-5"}"#

    #expect(ClaudeModelCatalog.modelValues(inLine: line) == ["claude-opus-4-8", "claude-haiku-4-5"])
  }

  @Test("Collects distinct valid ids from a JSONL document, dropping noise")
  func collectsValidIdentifiersFromDocument() {
    let jsonl = """
    {"type":"user","message":{"role":"user"}}
    {"type":"assistant","message":{"model":"claude-opus-4-8"}}
    {"type":"assistant","message":{"model":"claude-opus-4-8"}}
    {"type":"assistant","message":{"model":"claude-opus-4-7"}}
    {"summary":"Claude Opus 4.8 did things"}
    {"type":"assistant","message":{"model":"gpt-5.5"}}
    """

    let ids = ClaudeModelCatalog.modelIdentifiers(inJSONL: jsonl)

    #expect(ids == ["claude-opus-4-8", "claude-opus-4-7"])
  }

  // MARK: - Directory discovery

  @Test("Discovers ids across files ordered most-recent-first")
  func discoversIdentifiersByRecency() throws {
    let directory = try makeTempProjects()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Older file uses 4-7; newer file uses 4-8. Newest should come first.
    try writeSession(
      named: "old.jsonl",
      model: "claude-opus-4-7",
      modified: Date(timeIntervalSince1970: 1_000),
      in: directory
    )
    try writeSession(
      named: "new.jsonl",
      model: "claude-opus-4-8",
      modified: Date(timeIntervalSince1970: 2_000),
      in: directory
    )

    let ids = ClaudeModelCatalog.discoverModelIdentifiers(inProjectsDirectory: directory)

    #expect(ids == ["claude-opus-4-8", "claude-opus-4-7"])
  }

  @Test("Returns empty when the projects directory does not exist")
  func emptyWhenDirectoryMissing() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("does_not_exist_\(UUID().uuidString)")

    #expect(ClaudeModelCatalog.discoverModelIdentifiers(inProjectsDirectory: missing).isEmpty)
  }

  // MARK: - availableModels

  @Test("availableModels lists aliases first, then discovered versioned ids")
  func availableModelsMergesAliasesAndDiscovery() async throws {
    let directory = try makeTempProjects()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeSession(
      named: "session.jsonl",
      model: "claude-opus-4-8",
      modified: Date(timeIntervalSince1970: 2_000),
      in: directory
    )

    let catalog = ClaudeModelCatalog(projectsDirectory: directory)
    let options = await catalog.availableModels()

    #expect(options.prefix(3).map(\.identifier) == ["opus", "sonnet", "haiku"])
    #expect(options.map(\.identifier).contains("claude-opus-4-8"))
    let discovered = options.first { $0.identifier == "claude-opus-4-8" }
    #expect(discovered?.detail == "Used in your sessions")
  }

  // MARK: - Helpers

  private func makeTempProjects() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude_catalog_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeSession(named name: String, model: String, modified: Date, in directory: URL) throws {
    let url = directory.appendingPathComponent(name)
    let line = #"{"type":"assistant","message":{"model":"\#(model)"}}"# + "\n"
    try line.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
  }
}
