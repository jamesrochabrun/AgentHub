//
//  InlineEditorState.swift
//  AgentHub
//
//  Created by Assistant on 1/16/26.
//

import SwiftUI

/// Observable state for the floating inline editor
@Observable @MainActor
final class InlineEditorState {
  /// Whether the editor is currently showing
  var isShowing: Bool = false

  /// The anchor point in window coordinates where the editor should appear
  var anchorPoint: CGPoint = .zero

  /// The line number that was clicked
  var lineNumber: Int = 0

  /// Which side of the diff was clicked ("left", "right", or "unified")
  var side: String = ""

  /// The file name being edited
  var fileName: String = ""

  // MARK: - Context Properties (for prompt building)

  /// The content of the clicked line
  var lineContent: String?

  /// The full file content for context
  var fullFileContent: String?

  // MARK: - Error State

  /// Error message if request failed
  var errorMessage: String?

  /// Shows the editor at the specified position with context
  func show(
    at point: CGPoint,
    lineNumber: Int,
    side: String,
    fileName: String,
    lineContent: String? = nil,
    fullFileContent: String? = nil
  ) {
    self.anchorPoint = point
    self.lineNumber = lineNumber
    self.side = side
    self.fileName = fileName
    self.lineContent = lineContent
    self.fullFileContent = fullFileContent
    self.errorMessage = nil
    self.isShowing = true
  }

  /// Dismisses the editor and resets state
  func dismiss() {
    isShowing = false
    errorMessage = nil
  }
}
