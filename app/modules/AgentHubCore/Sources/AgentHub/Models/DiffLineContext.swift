//
//  DiffLineContext.swift
//  AgentHub
//

import Foundation

/// Context for a line or range of lines selected in a diff view.
///
/// Bundles together all the metadata about a user's selection so that
/// callbacks like submit and add-comment receive a single value instead
/// of a long parameter list.
struct DiffLineContext: Sendable {
  /// The start line number of the selection
  let lineNumber: Int

  /// The end line number when a multi-line range is selected (nil for single line)
  let endLineNumber: Int?

  /// Which side of the diff ("left", "right", or "unified")
  let side: String

  /// The file path being reviewed
  let fileName: String

  /// The content of the selected line(s)
  let lineContent: String
}
