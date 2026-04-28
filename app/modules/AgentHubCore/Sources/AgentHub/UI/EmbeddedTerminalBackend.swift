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
    let rawValue = UserDefaults.standard.object(forKey: AgentHubDefaults.terminalBackend) as? Int
      ?? EmbeddedTerminalBackend.ghostty.rawValue
    return EmbeddedTerminalBackend(rawValue: rawValue) ?? .ghostty
  }
}
