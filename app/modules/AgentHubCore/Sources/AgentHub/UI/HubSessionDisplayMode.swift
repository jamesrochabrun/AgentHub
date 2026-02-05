//
//  HubSessionDisplayMode.swift
//  AgentHub
//
//  Created by Assistant on 2/4/26.
//

import Foundation

public enum HubSessionDisplayMode: Int, CaseIterable {
  case single = 0
  case allMonitored = 1

  var title: String {
    switch self {
    case .single: return "Single"
    case .allMonitored: return "Multi"
    }
  }

  var displayName: String {
    title
  }

  var icon: String {
    switch self {
    case .single: return "1.square"
    case .allMonitored: return "square.grid.2x2"
    }
  }
}

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
