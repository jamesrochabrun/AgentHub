//
//  WebPreviewDesignToolsMode.swift
//  AgentHub
//
//  Presentation mode for the debug web preview design editing surface.
//

import Foundation

enum WebPreviewDesignToolsMode: String, CaseIterable, Equatable, Identifiable, Sendable {
  case inline
  case panel

  var id: String { rawValue }

  var settingsLabel: String {
    switch self {
    case .inline:
      "Inline"
    case .panel:
      "Panel"
    }
  }

  var settingsDescription: String {
    switch self {
    case .inline:
      "Shows only the floating inline toolbar on selected elements."
    case .panel:
      "Shows only the Design/Code/Console inspector rail."
    }
  }
}
