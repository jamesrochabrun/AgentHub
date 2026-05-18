//
//  EmbeddedTerminalBackend.swift
//  AgentHub
//

import Foundation

public enum EmbeddedTerminalBackend: Int, CaseIterable, Sendable {
  case ghostty = 0
  case regular = 1

  public var label: String {
    switch self {
    case .ghostty: return "Ghostty"
    case .regular: return "Regular"
    }
  }

  public static var storedPreference: EmbeddedTerminalBackend {
    storedPreference(in: .standard)
  }

  public static func storedPreference(in defaults: UserDefaults) -> EmbeddedTerminalBackend {
    let rawValue = defaults.object(forKey: AgentHubDefaults.terminalBackend) as? Int
      ?? EmbeddedTerminalBackend.regular.rawValue
    return EmbeddedTerminalBackend(rawValue: rawValue) ?? .regular
  }
}
