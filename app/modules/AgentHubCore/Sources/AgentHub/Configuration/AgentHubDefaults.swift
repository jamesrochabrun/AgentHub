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
  /// Type: Int (default: 0)
  public static let approvalTimeout = "\(keyPrefix)sessions.approvalTimeout"

  // MARK: - Notification Settings

  /// Whether notification sounds are enabled
  /// Type: Bool (default: true)
  public static let notificationSoundsEnabled = "\(keyPrefix)notifications.soundsEnabled"

  /// Persisted selected repositories (JSON-encoded array of paths)
  /// Type: Data (JSON-encoded [String])
  /// Note: Used with provider suffix (e.g., `.claude` or `.codex`) for provider-specific storage
  public static let selectedRepositories = "\(keyPrefix)sessions.selectedRepositories"

  /// Persisted monitored session IDs (JSON-encoded array of session IDs)
  /// Type: Data (JSON-encoded [String])
  public static let monitoredSessionIds = "\(keyPrefix)sessions.monitoredSessionIds"

  /// Persisted session IDs that have terminal view enabled
  /// Type: Data (JSON-encoded [String])
  public static let sessionsWithTerminalView = "\(keyPrefix)sessions.sessionsWithTerminalView"

  // MARK: - Provider Settings

  /// Base key for enabled providers
  /// Usage: Use with provider suffix, e.g. `enabledProviders + ".claude"`
  /// Type: Bool (default: true)
  public static let enabledProviders = "\(keyPrefix)settings.enabledProviders"

  /// Selected provider in side panel segmented control
  /// Type: String (default: "Claude")
  public static let selectedSidePanelProvider = "\(keyPrefix)sidepanel.selectedProvider"

  // MARK: - Theme Settings

  // MARK: - UI Settings

  /// Monitoring panel layout mode (list, 2-column, 3-column grid)
  /// Type: Int (default: 0 = list)
  public static let monitoringPanelLayoutMode = "\(keyPrefix)ui.monitoringPanelLayoutMode"

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
}
