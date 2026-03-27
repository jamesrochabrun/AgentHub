//
//  WebInspectInputPlacement.swift
//  WebInspector
//
//  Placement options for the inspect-mode text input overlay.
//

import Foundation

/// Controls where the inspect-mode input editor is placed.
public enum WebInspectInputPlacement: Sendable {
  /// Keeps the input editor attached to the bottom edge of the preview.
  case bottom
  /// Positions the input editor below the selected element and clamps it to the visible viewport.
  case selectionAnchored
}
