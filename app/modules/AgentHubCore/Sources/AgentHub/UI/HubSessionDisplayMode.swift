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
    case .allMonitored: return "All"
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
