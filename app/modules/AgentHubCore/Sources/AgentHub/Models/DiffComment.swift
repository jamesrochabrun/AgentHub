//
//  DiffComment.swift
//  AgentHub
//
//  Created by Assistant on 1/29/26.
//

import Foundation

/// A review comment on a specific line in a diff view.
///
/// Supports PR-style code review where users can leave multiple comments
/// on different lines across files, then batch-send them to Claude.
struct DiffComment: Identifiable, Equatable, Sendable {
  /// Unique identifier for this comment
  let id: UUID
  /// When the comment was created
  let timestamp: Date
  /// Absolute path of the file being commented on
  let filePath: String
  /// The start (or only) line number of the comment
  let lineNumber: Int
  /// The end line number when the comment spans a multi-line drag selection
  let endLineNumber: Int?
  /// Which side of the diff this comment belongs to (`"left"`, `"right"`, or `"unified"`)
  let side: String
  /// Source code content of the selected line(s)
  let lineContent: String
  /// The user's review comment text (mutable so it can be edited in-place)
  var text: String

  /// Unique key for identifying a comment's location.
  /// Used to detect if a line already has a comment.
  var locationKey: String {
    if let end = endLineNumber {
      return "\(filePath):\(lineNumber)-\(end):\(side)"
    }
    return "\(filePath):\(lineNumber):\(side)"
  }

  /// Display label for the line reference (e.g. "Line 42" or "Lines 42-50")
  var lineLabel: String {
    if let end = endLineNumber {
      return "Lines \(lineNumber)-\(end)"
    }
    return "Line \(lineNumber)"
  }

  init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    filePath: String,
    lineNumber: Int,
    endLineNumber: Int? = nil,
    side: String,
    lineContent: String,
    text: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.filePath = filePath
    self.lineNumber = lineNumber
    self.endLineNumber = endLineNumber
    self.side = side
    self.lineContent = lineContent
    self.text = text
  }
}
