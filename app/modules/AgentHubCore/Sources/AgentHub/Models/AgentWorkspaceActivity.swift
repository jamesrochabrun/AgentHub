//
//  AgentWorkspaceActivity.swift
//  AgentHub
//

public enum AgentWorkspaceActivity: Int, Comparable, Equatable, Sendable {
  case idle
  case ready
  case working
  case needsAttention

  public var label: String {
    switch self {
    case .idle: "Idle"
    case .ready: "Ready"
    case .working: "Working"
    case .needsAttention: "Needs attention"
    }
  }

  public var systemImage: String {
    switch self {
    case .idle: "circle"
    case .ready: "checkmark.circle"
    case .working: "gearshape"
    case .needsAttention: "exclamationmark.circle"
    }
  }

  public static func < (lhs: AgentWorkspaceActivity, rhs: AgentWorkspaceActivity) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}
