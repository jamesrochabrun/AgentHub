//
//  ElementInspectState.swift
//  WebInspector
//
//  Observable state for the web element inspector overlay.
//

import SwiftUI

/// The inspector interaction mode.
public enum InspectMode: Sendable {
  /// User types an instruction before sending (default).
  case input
  /// Element context is sent immediately on selection.
  case context
}

/// Observable state controlling the web element inspector lifecycle.
///
/// Activate -> hover -> click -> input -> submit/dismiss.
@Observable @MainActor
public final class ElementInspectState {
  /// Whether inspect mode is currently active (highlight-on-hover enabled)
  public var isActive = false

  /// The current inspector interaction mode.
  public var mode: InspectMode = .input

  /// The element the user clicked; non-nil when the input overlay should show
  public var selectedElement: ElementInspectorData?

  /// The selected element's live bounding rect in viewport coordinates.
  public var selectedElementViewportRect: CGRect?

  /// Whether the instruction input overlay is visible
  public var isInputShowing: Bool { selectedElement != nil }

  /// Convenience check for context mode.
  public var isContextMode: Bool { mode == .context }

  public init() {}

  /// Activates inspect mode.
  public func activate(mode: InspectMode = .input) {
    self.mode = mode
    isActive = true
    clearSelection()
  }

  /// Deactivates inspect mode and clears any selected element.
  public func deactivate() {
    isActive = false
    clearSelection()
  }

  /// Records the clicked element and shows the input overlay.
  public func selectElement(_ element: ElementInspectorData) {
    selectedElement = element
    selectedElementViewportRect = element.boundingRect
  }

  /// Updates the selected element's viewport rect without replacing the selection.
  public func updateSelectedElementViewportRect(_ rect: CGRect) {
    guard selectedElement != nil else { return }
    selectedElementViewportRect = rect
  }

  /// Dismisses the input overlay without deactivating inspect mode.
  public func dismissInput() {
    clearSelection()
  }

  private func clearSelection() {
    selectedElement = nil
    selectedElementViewportRect = nil
  }
}
