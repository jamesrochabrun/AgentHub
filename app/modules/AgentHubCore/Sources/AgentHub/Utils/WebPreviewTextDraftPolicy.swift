//
//  WebPreviewTextDraftPolicy.swift
//  AgentHub
//
//  Decides when a page read-back may replace the text the user is editing.
//
//  The page bridge reports element text trimmed and whitespace-collapsed, so a
//  naive "keep the field in sync with the DOM" binding erases the trailing
//  space the user just typed — which is what made it impossible to keep typing
//  at the end of a string. The draft wins while the field is focused, and an
//  unfocused draft only yields to text that differs by more than whitespace.
//

import Foundation

enum WebPreviewTextDraftPolicy {
  /// Whether an incoming page/source read should replace the local draft.
  static func shouldAdoptIncomingText(
    _ incoming: String,
    draft: String,
    isEditing: Bool
  ) -> Bool {
    guard !isEditing else { return false }
    return normalized(incoming) != normalized(draft)
  }

  /// Whitespace-insensitive comparison form.
  static func normalized(_ text: String) -> String {
    text
      .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
      .joined(separator: " ")
  }
}
