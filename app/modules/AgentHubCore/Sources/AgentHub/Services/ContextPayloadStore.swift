//
//  ContextPayloadStore.swift
//  AgentHub
//
//  Decides how an assembled context block travels to the CLI. Small blocks go
//  inline in the first prompt; oversized blocks are written to an
//  AgentHub-owned file under Application Support and the prompt references the
//  path instead (large pastes stall the Claude TUI, and Codex receives its
//  prompt via argv). Nothing is ever written inside a user's repository.
//

import Foundation

public enum ContextPromptPayload: Equatable, Sendable {
  case inline(String)
  case fileReference(path: String, prompt: String)

  public var promptText: String {
    switch self {
    case .inline(let block):
      return block
    case .fileReference(_, let prompt):
      return prompt
    }
  }
}

public protocol ContextPayloadStoring: Sendable {
  func materializeIfNeeded(block: String) throws -> ContextPromptPayload
}

public struct ContextPayloadStore: ContextPayloadStoring {

  /// 48 KB ≈ 14K estimated tokens inline. Above this the Claude terminal paste
  /// visibly stalls, so the block is referenced by file path instead. The same
  /// threshold applies to Codex (argv) so assembly output stays provider-agnostic.
  public static let inlineByteThreshold = 48 * 1024

  /// Payloads are read once at session start; anything a week old is dead.
  public static let stalePayloadMaxAge: TimeInterval = 7 * 24 * 60 * 60

  public let directoryURL: URL
  public let inlineByteThreshold: Int

  /// Resolves through `AgentHubApplicationSupport` so test processes and
  /// `AGENTHUB_APP_SUPPORT_DIR` overrides never touch the user's real payloads.
  public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
    AgentHubApplicationSupport.baseDirectoryURL
      .appendingPathComponent("context", isDirectory: true)
      .appendingPathComponent("payloads", isDirectory: true)
  }

  public init(
    directoryURL: URL = Self.defaultDirectoryURL(),
    inlineByteThreshold: Int = Self.inlineByteThreshold
  ) {
    self.directoryURL = directoryURL
    self.inlineByteThreshold = inlineByteThreshold
  }

  public func materializeIfNeeded(block: String) throws -> ContextPromptPayload {
    guard block.utf8.count > inlineByteThreshold else {
      return .inline(block)
    }

    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    pruneStalePayloads()

    let fileURL = directoryURL.appendingPathComponent("context-\(UUID().uuidString).md")
    try block.write(to: fileURL, atomically: true, encoding: .utf8)

    let prompt = """
      <context>
      Curated context for this session (file map, file contents, instructions) is in:
      \(fileURL.path)
      Read that file before doing anything else.
      </context>
      """
    return .fileReference(path: fileURL.path, prompt: prompt)
  }

  private func pruneStalePayloads() {
    let fileManager = FileManager.default
    guard let contents = try? fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    let cutoff = Date().addingTimeInterval(-Self.stalePayloadMaxAge)
    for url in contents {
      // Only reap files this store wrote — never other content that ends up
      // in (or shares) the directory.
      guard url.lastPathComponent.hasPrefix("context-"), url.pathExtension == "md" else { continue }
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      if let modified, modified < cutoff {
        try? fileManager.removeItem(at: url)
      }
    }
  }
}
