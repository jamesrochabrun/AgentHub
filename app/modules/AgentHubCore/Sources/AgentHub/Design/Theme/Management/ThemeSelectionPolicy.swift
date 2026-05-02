//
//  ThemeSelectionPolicy.swift
//  AgentHub
//
//  Backend-aware theme availability and persistence rules.
//

import Foundation
import AgentHubTerminalUI

enum ThemeSelectionPolicy {
  static let ghosttyThemeId = "ghostty.yaml"
  static let defaultRegularThemeId = "singularity.yaml"

  static let regularBundledYAMLThemeFileIds = [
    "sentry.yaml",
    "rigel.yaml",
    "vela.yaml",
    "antares.yaml",
    "singularity.yaml",
    "nebula.yaml",
    "helios.yaml",
  ]

  static let allBundledYAMLThemeFileIds = regularBundledYAMLThemeFileIds + [ghosttyThemeId]

  static func defaultThemeId(for backend: EmbeddedTerminalBackend) -> String {
    switch backend {
    case .ghostty:
      return ghosttyThemeId
    case .regular:
      return defaultRegularThemeId
    }
  }

  static func bundledYAMLThemeFileIds(for backend: EmbeddedTerminalBackend) -> [String] {
    switch backend {
    case .ghostty:
      return [ghosttyThemeId]
    case .regular:
      return regularBundledYAMLThemeFileIds
    }
  }

  static func matchingBundledYAMLFileId(
    for value: String,
    in fileIds: [String] = allBundledYAMLThemeFileIds
  ) -> String? {
    let normalized = normalizedThemeToken(value)
    guard !normalized.isEmpty else { return nil }

    return fileIds.first { fileId in
      let baseName = baseName(for: fileId)
      return normalized == baseName
        || normalized == fileId
        || normalized == "\(baseName).yml"
    }
  }

  static func canonicalThemeId(
    for value: String,
    backend: EmbeddedTerminalBackend
  ) -> String? {
    if backend == .regular {
      return canonicalRegularThemeId(for: value)
    }

    return matchingBundledYAMLFileId(
      for: value,
      in: bundledYAMLThemeFileIds(for: backend)
    )
  }

  @discardableResult
  static func coercePersistedThemeSelection(
    defaults: UserDefaults = .standard,
    backend: EmbeddedTerminalBackend = .storedPreference
  ) -> String {
    let savedThemeId = defaults.string(forKey: AgentHubDefaults.selectedTheme)

    switch backend {
    case .ghostty:
      if let savedThemeId,
         !isGhosttyTheme(savedThemeId),
         let regularThemeId = canonicalRegularThemeId(for: savedThemeId) {
        defaults.set(regularThemeId, forKey: AgentHubDefaults.previousNonGhosttyTheme)
      }
      defaults.set(ghosttyThemeId, forKey: AgentHubDefaults.selectedTheme)
      return ghosttyThemeId

    case .regular:
      if let savedThemeId,
         let regularThemeId = canonicalRegularThemeId(for: savedThemeId) {
        defaults.set(regularThemeId, forKey: AgentHubDefaults.selectedTheme)
        defaults.set(regularThemeId, forKey: AgentHubDefaults.previousNonGhosttyTheme)
        return regularThemeId
      }

      let previousThemeId = defaults.string(forKey: AgentHubDefaults.previousNonGhosttyTheme)
      let restoredThemeId = canonicalRegularThemeId(for: previousThemeId) ?? defaultRegularThemeId
      defaults.set(restoredThemeId, forKey: AgentHubDefaults.selectedTheme)
      defaults.set(restoredThemeId, forKey: AgentHubDefaults.previousNonGhosttyTheme)
      return restoredThemeId
    }
  }

  static func persistThemeSelection(
    _ themeId: String,
    defaults: UserDefaults = .standard,
    backend: EmbeddedTerminalBackend = .storedPreference
  ) {
    switch backend {
    case .ghostty:
      defaults.set(ghosttyThemeId, forKey: AgentHubDefaults.selectedTheme)
    case .regular:
      let regularThemeId = canonicalRegularThemeId(for: themeId) ?? defaultRegularThemeId
      defaults.set(regularThemeId, forKey: AgentHubDefaults.selectedTheme)
      defaults.set(regularThemeId, forKey: AgentHubDefaults.previousNonGhosttyTheme)
    }
  }

  static func isGhosttyTheme(_ value: String) -> Bool {
    matchingBundledYAMLFileId(for: value, in: [ghosttyThemeId]) == ghosttyThemeId
  }

  private static func canonicalRegularThemeId(for value: String?) -> String? {
    guard let value else { return nil }
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty, !isGhosttyTheme(trimmedValue) else { return nil }

    if AppTheme(rawValue: trimmedValue) != nil {
      return trimmedValue
    }

    if let bundledThemeId = matchingBundledYAMLFileId(for: trimmedValue, in: regularBundledYAMLThemeFileIds) {
      return bundledThemeId
    }

    if isYAMLFileName(trimmedValue) {
      return (trimmedValue as NSString).lastPathComponent
    }

    return nil
  }

  private static func normalizedThemeToken(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func baseName(for fileId: String) -> String {
    fileId
      .replacingOccurrences(of: ".yaml", with: "")
      .replacingOccurrences(of: ".yml", with: "")
  }

  private static func isYAMLFileName(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return lowercased.hasSuffix(".yaml") || lowercased.hasSuffix(".yml")
  }
}
