//
//  ContextSelection.swift
//  AgentHub
//
//  Curated launch context: the files (and standing instructions) handed to an
//  agent before its first turn. Project files are stored as project-relative
//  paths so a selection stays valid inside a freshly created worktree of the
//  same repository; anything outside the repo — another folder, a document, a
//  book — is stored as an absolute path.
//

import Foundation

public struct ContextFileSelection: Codable, Equatable, Sendable, Identifiable {
  public var id: String { relativePath }
  public let relativePath: String

  public init(relativePath: String) {
    self.relativePath = relativePath
  }
}

/// Pasted text stored directly in the selection — notes, snippets, prompt
/// material that has no file on disk.
public struct ContextTextSnippet: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public var title: String
  public var content: String

  public init(id: String = UUID().uuidString, title: String, content: String) {
    self.id = id
    self.title = title
    self.content = content
  }
}

public struct ContextSelection: Equatable, Sendable {
  /// Project files, relative to the repository root.
  public var files: [ContextFileSelection]
  /// Files outside the repository, as absolute paths (other repos, documents,
  /// books, notes — anything the user pointed at).
  public var externalPaths: [String]
  /// Pasted text stored directly in the set (no file on disk).
  public var textSnippets: [ContextTextSnippet]
  public var instructions: String

  public init(
    files: [ContextFileSelection] = [],
    externalPaths: [String] = [],
    textSnippets: [ContextTextSnippet] = [],
    instructions: String = ""
  ) {
    self.files = files
    self.externalPaths = externalPaths
    self.textSnippets = textSnippets
    self.instructions = instructions
  }

  public var isEmpty: Bool {
    files.isEmpty && externalPaths.isEmpty && textSnippets.isEmpty
      && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

// Custom Codable so selections saved before `externalPaths`/`textSnippets`
// existed still decode (profile payloads persist in SQLite).
extension ContextSelection: Codable {
  private enum CodingKeys: String, CodingKey {
    case files
    case externalPaths
    case textSnippets
    case instructions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    files = try container.decodeIfPresent([ContextFileSelection].self, forKey: .files) ?? []
    externalPaths = try container.decodeIfPresent([String].self, forKey: .externalPaths) ?? []
    textSnippets = try container.decodeIfPresent([ContextTextSnippet].self, forKey: .textSnippets) ?? []
    instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
  }
}
