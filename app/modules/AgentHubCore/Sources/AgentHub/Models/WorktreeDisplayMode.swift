//
//  WorktreeDisplayMode.swift
//  AgentHub
//

import Foundation

public enum WorktreeDisplayMode: String, CaseIterable, Identifiable, Sendable, Codable {
  case parent
  case separateModules

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .parent:
      return "Group under parent module"
    case .separateModules:
      return "Show worktrees as modules"
    }
  }

  public var settingsDescription: String {
    switch self {
    case .parent:
      return "Worktree sessions appear under their parent module."
    case .separateModules:
      return "Worktrees appear as separate module sections without adding them as saved repositories."
    }
  }
}
