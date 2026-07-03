//
//  WebPreviewPendingDesignEdits.swift
//  AgentHub
//
//  Pending design edits captured in Edit Mode. Style and text changes are
//  batched per element and applied to source by the session's agent instead
//  of direct file writes.
//

import Canvas
import Foundation

/// A single pending CSS property change, deduped by property with last-wins values.
struct WebPreviewPendingStyleChange: Equatable, Sendable {
  let property: String
  /// The first-seen value before any pending edit, when one was known.
  let oldValue: String?
  var newValue: String
}

/// A pending text-content replacement for the selected element.
struct WebPreviewPendingTextChange: Equatable, Sendable {
  /// The text before any pending edit, when one was known.
  let oldText: String?
  var newText: String
}

/// All pending design edits for one selected element.
struct WebPreviewPendingDesignEditBatch: Equatable, Sendable {
  let element: ElementInspectorData
  private(set) var styleChanges: [WebPreviewPendingStyleChange] = []
  private(set) var textChange: WebPreviewPendingTextChange?

  init(element: ElementInspectorData) {
    self.element = element
  }

  var isEmpty: Bool {
    styleChanges.isEmpty && textChange == nil
  }

  var changeCount: Int {
    styleChanges.count + (textChange == nil ? 0 : 1)
  }

  mutating func recordStyleChange(property: String, oldValue: String?, newValue: String) {
    let normalizedOld = oldValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

    if let index = styleChanges.firstIndex(where: { $0.property == property }) {
      // Reverting to the first-seen value cancels the pending change.
      if let originalValue = styleChanges[index].oldValue, originalValue == newValue {
        styleChanges.remove(at: index)
        return
      }
      styleChanges[index].newValue = newValue
      return
    }

    if let normalizedOld, normalizedOld == newValue {
      return
    }

    styleChanges.append(WebPreviewPendingStyleChange(
      property: property,
      oldValue: normalizedOld,
      newValue: newValue
    ))
  }

  mutating func removeStyleChange(property: String) {
    styleChanges.removeAll { $0.property == property }
  }

  mutating func recordTextChange(oldText: String?, newText: String) {
    if let existing = textChange {
      if let originalText = existing.oldText, originalText == newText {
        textChange = nil
        return
      }
      textChange = WebPreviewPendingTextChange(oldText: existing.oldText, newText: newText)
      return
    }

    if let oldText, oldText == newText {
      return
    }

    textChange = WebPreviewPendingTextChange(oldText: oldText, newText: newText)
  }
}

/// The element-anchored agent instruction produced when a pending batch is
/// handed off for sending (Apply button, element switch, or panel close).
struct WebPreviewPendingDesignEditHandoff: Equatable, Sendable {
  let element: ElementInspectorData
  let instruction: String
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
