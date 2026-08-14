import Foundation
import Testing

@testable import AgentHubCore

@Suite("Context payload store")
struct ContextPayloadStoreTests {

  private func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("context-payloads-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  @Test("Blocks at or below the threshold stay inline")
  func inlineBelowThreshold() throws {
    try withTempDirectory { directory in
      let store = ContextPayloadStore(directoryURL: directory, inlineByteThreshold: 100)
      let block = String(repeating: "a", count: 100)

      let payload = try store.materializeIfNeeded(block: block)

      #expect(payload == .inline(block))
      #expect(payload.promptText == block)
      // Nothing written for inline payloads (directory not even created).
      #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
  }

  @Test("Oversized blocks are written to a file and referenced by path")
  func fileReferenceAboveThreshold() throws {
    try withTempDirectory { directory in
      let store = ContextPayloadStore(directoryURL: directory, inlineByteThreshold: 100)
      let block = String(repeating: "b", count: 101)

      let payload = try store.materializeIfNeeded(block: block)

      guard case .fileReference(let path, let prompt) = payload else {
        Issue.record("Expected fileReference, got \(payload)")
        return
      }
      #expect(prompt.contains(path))
      #expect(prompt.contains("Read that file before doing anything else."))
      #expect(payload.promptText == prompt)
      #expect(try String(contentsOfFile: path, encoding: .utf8) == block)
      #expect(path.hasPrefix(directory.path))
      #expect(path.hasSuffix(".md"))
    }
  }

  @Test("Stale payloads are pruned on write; fresh ones survive")
  func prunesStalePayloads() throws {
    try withTempDirectory { directory in
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let staleURL = directory.appendingPathComponent("context-stale.md")
      let freshURL = directory.appendingPathComponent("context-fresh.md")
      try "stale".write(to: staleURL, atomically: true, encoding: .utf8)
      try "fresh".write(to: freshURL, atomically: true, encoding: .utf8)
      let staleDate = Date().addingTimeInterval(-ContextPayloadStore.stalePayloadMaxAge - 3600)
      try FileManager.default.setAttributes(
        [.modificationDate: staleDate], ofItemAtPath: staleURL.path)

      let store = ContextPayloadStore(directoryURL: directory, inlineByteThreshold: 10)
      _ = try store.materializeIfNeeded(block: String(repeating: "c", count: 11))

      #expect(!FileManager.default.fileExists(atPath: staleURL.path))
      #expect(FileManager.default.fileExists(atPath: freshURL.path))
    }
  }

  @Test("Pruning only touches payload files the store wrote")
  func pruneIsScopedToOwnPayloads() throws {
    try withTempDirectory { directory in
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let foreignURL = directory.appendingPathComponent("user-notes.md")
      let wrongExtensionURL = directory.appendingPathComponent("context-export.json")
      try "keep me".write(to: foreignURL, atomically: true, encoding: .utf8)
      try "{}".write(to: wrongExtensionURL, atomically: true, encoding: .utf8)
      let staleDate = Date().addingTimeInterval(-ContextPayloadStore.stalePayloadMaxAge - 3600)
      for url in [foreignURL, wrongExtensionURL] {
        try FileManager.default.setAttributes(
          [.modificationDate: staleDate], ofItemAtPath: url.path)
      }

      let store = ContextPayloadStore(directoryURL: directory, inlineByteThreshold: 10)
      _ = try store.materializeIfNeeded(block: String(repeating: "c", count: 11))

      #expect(FileManager.default.fileExists(atPath: foreignURL.path))
      #expect(FileManager.default.fileExists(atPath: wrongExtensionURL.path))
    }
  }

  @Test("The default directory resolves inside the sandboxed app-support base")
  func defaultDirectoryIsSandboxSafe() {
    let directory = ContextPayloadStore.defaultDirectoryURL()
    #expect(directory.path.hasPrefix(AgentHubApplicationSupport.baseDirectoryURL.path))
    // Under the test runner the base is a per-process temp sandbox, so payload
    // writes in tests can never land in the user's real Application Support.
    #expect(!directory.path.contains("/Library/Application Support/AgentHub/"))
  }

  @Test("Threshold compares UTF-8 bytes, not characters")
  func thresholdUsesUTF8Bytes() throws {
    try withTempDirectory { directory in
      let store = ContextPayloadStore(directoryURL: directory, inlineByteThreshold: 5)
      // "éé" is 2 characters but 4 UTF-8 bytes — inline at a 5-byte threshold.
      let inline = try store.materializeIfNeeded(block: "éé")
      #expect(inline == .inline("éé"))

      // "ééé" is 6 bytes — over the 5-byte threshold.
      let reference = try store.materializeIfNeeded(block: "ééé")
      guard case .fileReference = reference else {
        Issue.record("Expected fileReference for 6-byte block")
        return
      }
    }
  }
}
