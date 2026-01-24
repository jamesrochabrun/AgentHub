//
//  AgentHubDefaults.swift
//  AgentHub
//
//  Centralized UserDefaults keys for AgentHub
//

import Foundation

/// Centralized UserDefaults keys for AgentHub
///
/// All keys are namespaced with `com.agenthub.` prefix to avoid collisions.
///
/// ## Usage
/// ```swift
/// // Read
/// let showLast = UserDefaults.standard.bool(forKey: AgentHubDefaults.showLastMessage)
///
/// // Write
/// UserDefaults.standard.set(true, forKey: AgentHubDefaults.showLastMessage)
/// ```
public enum AgentHubDefaults {

  /// Prefix for all AgentHub UserDefaults keys
  public static let keyPrefix = "com.agenthub."

  // MARK: - Session Settings

  /// Whether to show the last message instead of first in session rows
  /// Type: Bool (default: false)
  public static let showLastMessage = "\(keyPrefix)sessions.showLastMessage"

  /// Seconds to wait before triggering approval alert sound
  /// Type: Int (default: 5)
  public static let approvalTimeout = "\(keyPrefix)sessions.approvalTimeout"

  /// Persisted selected repositories (JSON-encoded array of paths)
  /// Type: Data (JSON-encoded [String])
  public static let selectedRepositories = "\(keyPrefix)sessions.selectedRepositories"

  /// Persisted monitored session IDs (JSON-encoded array of session IDs)
  /// Type: Data (JSON-encoded [String])
  public static let monitoredSessionIds = "\(keyPrefix)sessions.monitoredSessionIds"

  /// Persisted session IDs that have terminal view enabled
  /// Type: Data (JSON-encoded [String])
  public static let sessionsWithTerminalView = "\(keyPrefix)sessions.sessionsWithTerminalView"

  /// Persisted session colors (sessionId -> hex color string)
  /// Type: Data (JSON-encoded [String: String])
  public static let sessionColors = "\(keyPrefix)sessions.sessionColors"

  // MARK: - Folder Settings

  /// Path to the AgentHub folder where cloned repositories are stored
  /// Type: String (default: ~/AgentHub)
  public static let agentHubFolderPath = "\(keyPrefix)folders.agentHubFolderPath"

  // MARK: - Theme Settings

  /// Selected color theme name
  /// Type: String (default: "claude")
  public static let selectedTheme = "\(keyPrefix)theme.selected"

  /// Custom primary color hex value
  /// Type: String (default: "#7C3AED")
  public static let customPrimaryHex = "\(keyPrefix)theme.customPrimaryHex"

  /// Custom secondary color hex value
  /// Type: String (default: "#FFB000")
  public static let customSecondaryHex = "\(keyPrefix)theme.customSecondaryHex"

  /// Custom tertiary color hex value
  /// Type: String (default: "#64748B")
  public static let customTertiaryHex = "\(keyPrefix)theme.customTertiaryHex"

  // MARK: - Migration

  /// Legacy keys mapping for migration
  private static let legacyKeyMappings: [String: String] = [
    "CLISessionsShowLastMessage": showLastMessage,
    "CLISessionsApprovalTimeout": approvalTimeout,
    "CLISessionsSelectedRepositories": selectedRepositories,
    "selectedTheme": selectedTheme,
    "customPrimaryHex": customPrimaryHex,
    "customSecondaryHex": customSecondaryHex,
    "customTertiaryHex": customTertiaryHex
  ]

  /// Migrates legacy UserDefaults keys to namespaced keys
  ///
  /// Call this once during app launch to migrate existing settings.
  /// The migration is idempotent - it only copies values if the new key doesn't exist.
  ///
  /// ```swift
  /// // In your App's init or onAppear
  /// AgentHubDefaults.migrateIfNeeded()
  /// ```
  public static func migrateIfNeeded() {
    let defaults = UserDefaults.standard
    let migrationKey = "\(keyPrefix)migration.completed"

    // Skip if already migrated
    guard !defaults.bool(forKey: migrationKey) else { return }

    for (legacyKey, newKey) in legacyKeyMappings {
      // Only migrate if legacy key exists and new key doesn't
      if defaults.object(forKey: legacyKey) != nil && defaults.object(forKey: newKey) == nil {
        if let value = defaults.object(forKey: legacyKey) {
          defaults.set(value, forKey: newKey)
        }
      }
    }

    defaults.set(true, forKey: migrationKey)
  }

  // MARK: - Session Colors

  /// Gets all session colors from UserDefaults
  /// - Returns: Dictionary mapping session IDs to hex color strings
  public static func getSessionColors() -> [String: String] {
    guard let data = UserDefaults.standard.data(forKey: sessionColors),
          let colors = try? JSONDecoder().decode([String: String].self, from: data) else {
      return [:]
    }
    return colors
  }

  /// Sets or removes a color for a specific session
  /// - Parameters:
  ///   - hex: The hex color string to set, or nil to remove
  ///   - sessionId: The session ID to set the color for
  public static func setSessionColor(_ hex: String?, for sessionId: String) {
    var colors = getSessionColors()
    if let hex = hex {
      colors[sessionId] = hex
    } else {
      colors.removeValue(forKey: sessionId)
    }

    if let data = try? JSONEncoder().encode(colors) {
      UserDefaults.standard.set(data, forKey: sessionColors)
    }
  }

  /// Gets the color for a specific session
  /// - Parameter sessionId: The session ID to get the color for
  /// - Returns: The hex color string, or nil if not set
  public static func getSessionColor(for sessionId: String) -> String? {
    return getSessionColors()[sessionId]
  }
}
