//
//  PanelSizeMode.swift
//  AgentHub
//
//  Panel size modes for collapsible panels.
//

import Foundation

// MARK: - PanelSizeMode

public enum PanelSizeMode: Int, CaseIterable {
  case collapsed = 0  // Header only (~40pt)
  case small = 1      // 250pt (current default)
  case medium = 2     // Center of available height (dynamic)
  case full = 3       // Full available height

  var chevronIcon: String {
    switch self {
    case .collapsed: return "chevron.up"
    case .small: return "chevron.down"
    case .medium: return "chevron.down"
    case .full: return "chevron.down.2"
    }
  }

  func next() -> PanelSizeMode {
    let allCases = PanelSizeMode.allCases
    guard let currentIndex = allCases.firstIndex(of: self) else { return .small }
    let nextIndex = (currentIndex + 1) % allCases.count
    return allCases[nextIndex]
  }
}
