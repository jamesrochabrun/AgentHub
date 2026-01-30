//
//  DiffCommentsState.swift
//  AgentHub
//
//  Created by Assistant on 1/29/26.
//

import SwiftUI

/// Observable state manager for PR-style review comments on diffs.
///
/// Manages a collection of comments keyed by location, allowing users to
/// accumulate multiple comments across lines/files before batch-sending to Claude.
@Observable @MainActor
final class DiffCommentsState {

  // MARK: - Properties

  /// Comments keyed by location (filePath:lineNumber:side)
  private(set) var comments: [String: DiffComment] = [:]

  /// Whether the comments panel is expanded
  var isPanelExpanded: Bool = false

  // MARK: - Computed Properties

  /// All comments ordered by timestamp (oldest first)
  var orderedComments: [DiffComment] {
    comments.values.sorted { $0.timestamp < $1.timestamp }
  }

  /// Comments grouped by file path
  var commentsByFile: [String: [DiffComment]] {
    Dictionary(grouping: comments.values) { $0.filePath }
      .mapValues { $0.sorted { $0.lineNumber < $1.lineNumber } }
  }

  /// Total number of comments
  var commentCount: Int {
    comments.count
  }

  /// Whether there are any pending comments
  var hasComments: Bool {
    !comments.isEmpty
  }

  // MARK: - Methods

  /// Adds or updates a comment at the specified location.
  ///
  /// - Parameters:
  ///   - filePath: The file path where the comment is made
  ///   - lineNumber: The line number of the comment
  ///   - side: Which side of the diff ("left", "right", or "unified")
  ///   - lineContent: The content of the line being commented on
  ///   - text: The comment text
  /// - Returns: The created or updated comment
  @discardableResult
  func addComment(
    filePath: String,
    lineNumber: Int,
    side: String,
    lineContent: String,
    text: String
  ) -> DiffComment {
    let locationKey = "\(filePath):\(lineNumber):\(side)"

    if var existingComment = comments[locationKey] {
      // Update existing comment
      existingComment.text = text
      comments[locationKey] = existingComment
      return existingComment
    } else {
      // Create new comment
      let comment = DiffComment(
        filePath: filePath,
        lineNumber: lineNumber,
        side: side,
        lineContent: lineContent,
        text: text
      )
      comments[locationKey] = comment
      return comment
    }
  }

  /// Updates the text of an existing comment.
  ///
  /// - Parameters:
  ///   - id: The ID of the comment to update
  ///   - newText: The new comment text
  func updateComment(id: UUID, newText: String) {
    guard let locationKey = comments.first(where: { $0.value.id == id })?.key else {
      return
    }
    comments[locationKey]?.text = newText
  }

  /// Removes a comment by its ID.
  ///
  /// - Parameter id: The ID of the comment to remove
  func removeComment(id: UUID) {
    guard let locationKey = comments.first(where: { $0.value.id == id })?.key else {
      return
    }
    comments.removeValue(forKey: locationKey)
  }

  /// Removes a comment by its location.
  ///
  /// - Parameters:
  ///   - filePath: The file path of the comment
  ///   - lineNumber: The line number of the comment
  ///   - side: The side of the diff
  func removeComment(filePath: String, lineNumber: Int, side: String) {
    let locationKey = "\(filePath):\(lineNumber):\(side)"
    comments.removeValue(forKey: locationKey)
  }

  /// Checks if a line already has a comment.
  ///
  /// - Parameters:
  ///   - filePath: The file path to check
  ///   - lineNumber: The line number to check
  ///   - side: The side of the diff
  /// - Returns: True if a comment exists at this location
  func hasComment(filePath: String, lineNumber: Int, side: String) -> Bool {
    let locationKey = "\(filePath):\(lineNumber):\(side)"
    return comments[locationKey] != nil
  }

  /// Gets the comment at a specific location.
  ///
  /// - Parameters:
  ///   - filePath: The file path
  ///   - lineNumber: The line number
  ///   - side: The side of the diff
  /// - Returns: The comment at this location, or nil if none exists
  func getComment(filePath: String, lineNumber: Int, side: String) -> DiffComment? {
    let locationKey = "\(filePath):\(lineNumber):\(side)"
    return comments[locationKey]
  }

  /// Clears all comments.
  func clearAll() {
    comments.removeAll()
  }

  /// Generates a formatted prompt for Claude from all comments.
  ///
  /// Format:
  /// ```
  /// I have the following review comments on the code changes:
  ///
  /// ## /full/path/to/FileName.swift
  ///
  /// **Line 42** (new):
  /// ```
  /// let result = calculateValue()
  /// ```
  /// Comment: Consider adding error handling here
  /// ```
  ///
  /// - Returns: The formatted prompt string
  func generatePrompt() -> String {
    guard hasComments else { return "" }

    var prompt = "I have the following review comments on the code changes:\n"

    for (filePath, fileComments) in commentsByFile {
      prompt += "\n## \(filePath)\n"

      for comment in fileComments {
        let sideLabel = comment.side == "left" ? "old" : "new"
        prompt += "\n**Line \(comment.lineNumber)** (\(sideLabel)):\n"
        prompt += "```\n\(comment.lineContent)\n```\n"
        prompt += "Comment: \(comment.text)\n"
      }
    }

    prompt += "\nPlease address these review comments."

    return prompt
  }
}
