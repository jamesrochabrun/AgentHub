//
//  GlobalSessionControlPanelDisplayMode.swift
//  AgentHubGlobalSessionPanel
//

import Foundation
import AgentHubCore

// MARK: - GlobalSessionControlPanelDisplayMode

public enum GlobalSessionControlPanelDisplayMode: Int, CaseIterable, Sendable {
  case regular = 0
  case compact = 1

  public static let defaultValue: GlobalSessionControlPanelDisplayMode = .regular

  public static func load(from defaults: UserDefaults) -> GlobalSessionControlPanelDisplayMode {
    let storedValue = defaults.object(forKey: AgentHubDefaults.globalSessionPanelDisplayMode)
    let rawValue: Int?
    if let value = storedValue as? Int {
      rawValue = value
    } else if let value = storedValue as? NSNumber {
      rawValue = value.intValue
    } else {
      rawValue = nil
    }

    guard let rawValue else {
      return defaultValue
    }
    return GlobalSessionControlPanelDisplayMode(rawValue: rawValue) ?? defaultValue
  }

  public func persist(to defaults: UserDefaults) {
    defaults.set(rawValue, forKey: AgentHubDefaults.globalSessionPanelDisplayMode)
  }
}
