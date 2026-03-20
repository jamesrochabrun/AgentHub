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
  let id: UUID
  let timestamp: Date
  let filePath: String
  let lineNumber: Int
  let endLineNumber: Int?  // Non-nil when comment spans a multi-line selection
  let side: String  // "left", "right", "unified"
  let lineContent: String
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
