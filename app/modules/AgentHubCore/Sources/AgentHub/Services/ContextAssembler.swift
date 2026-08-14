//
//  ContextAssembler.swift
//  AgentHub
//
//  Builds the exact context block handed to an agent from loaded file contents
//  and user instructions. Output is deterministic: files are sorted by path
//  regardless of selection order, so the same selection always produces the
//  same block (previews, tests, and token estimates stay stable).
//

import Foundation

public struct ContextAssemblyInput: Sendable {
  public let files: [ContextLoadedFile]
  public let missingPaths: [String]
  /// Files that are part of the context but not inlined (binary or oversized);
  /// the agent is told to read them with its own tools.
  public let attachmentPaths: [String]
  /// Pasted text stored directly in the selection.
  public let textSnippets: [ContextTextSnippet]
  public let instructions: String

  public init(
    files: [ContextLoadedFile],
    missingPaths: [String] = [],
    attachmentPaths: [String] = [],
    textSnippets: [ContextTextSnippet] = [],
    instructions: String = ""
  ) {
    self.files = files
    self.missingPaths = missingPaths
    self.attachmentPaths = attachmentPaths
    self.textSnippets = textSnippets
    self.instructions = instructions
  }
}

public struct ContextAssemblyResult: Equatable, Sendable {
  public let block: String
  public let byteCount: Int

  public init(block: String) {
    self.block = block
    self.byteCount = block.utf8.count
  }
}

public protocol ContextAssembling: Sendable {
  func assemble(_ input: ContextAssemblyInput) -> ContextAssemblyResult
}

public struct ContextAssembler: ContextAssembling {

  public init() {}

  public func assemble(_ input: ContextAssemblyInput) -> ContextAssemblyResult {
    let files = input.files.sorted { $0.relativePath < $1.relativePath }
    let missing = input.missingPaths.sorted()
    let attachments = input.attachmentPaths.sorted()
    let snippets = input.textSnippets.sorted {
      ($0.title, $0.id) < ($1.title, $1.id)
    }
    let instructions = input.instructions.trimmingCharacters(in: .whitespacesAndNewlines)

    var sections: [String] = []

    if !files.isEmpty || !missing.isEmpty || !attachments.isEmpty || !snippets.isEmpty {
      var mapEntries = files.map { "\($0.relativePath) (\($0.metrics.lineCount) lines)" }
      mapEntries.append(contentsOf: missing.map { "\($0) (missing)" })
      mapEntries.append(contentsOf: attachments.map { "\($0) (attachment — read separately)" })
      mapEntries.append(contentsOf: snippets.map { "\($0.title) (pasted text)" })
      mapEntries.sort()
      sections.append("<file_map>\n\(mapEntries.joined(separator: "\n"))\n</file_map>")
    }

    if !files.isEmpty {
      let fileBlocks = files.map { file in
        "<file path=\"\(Self.escapeAttribute(file.relativePath))\">\n\(file.content)\n</file>"
      }
      sections.append("<files>\n\(fileBlocks.joined(separator: "\n"))\n</files>")
    }

    if !snippets.isEmpty {
      let snippetBlocks = snippets.map { snippet in
        "<snippet title=\"\(Self.escapeAttribute(snippet.title))\">\n\(snippet.content)\n</snippet>"
      }
      sections.append("<snippets>\n\(snippetBlocks.joined(separator: "\n"))\n</snippets>")
    }

    if !attachments.isEmpty {
      sections.append(
        "<attachments>\nThese files are part of the context but are not inlined (binary or large). Read them with your file tools:\n\(attachments.joined(separator: "\n"))\n</attachments>"
      )
    }

    if !instructions.isEmpty {
      sections.append("<instructions>\n\(instructions)\n</instructions>")
    }

    guard !sections.isEmpty else {
      return ContextAssemblyResult(block: "")
    }

    return ContextAssemblyResult(block: "<context>\n\(sections.joined(separator: "\n"))\n</context>")
  }

  /// User-typed snippet titles and arbitrary paths land in attribute positions;
  /// a stray `"` or `<` there would break the block structure for the agent.
  private static func escapeAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
