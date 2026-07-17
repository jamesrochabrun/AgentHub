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

  /// Whether push notifications are enabled for tool approvals
  /// Type: Bool (default: true)
  public static let pushNotificationsEnabled = "\(keyPrefix)notifications.pushEnabled"

  // MARK: - Provider Settings

  /// Base key for enabled providers
  /// Usage: Use with provider suffix, e.g. `enabledProviders + ".claude"`
  /// Type: Bool (default: true)
  public static let enabledProviders = "\(keyPrefix)settings.enabledProviders"

  // MARK: - CLI Command Settings

  /// Custom Claude CLI command name
  /// Type: String (default: "claude")
  public static let claudeCommand = "\(keyPrefix)cli.claudeCommand"

  /// Custom Codex CLI command name
  /// Type: String (default: "codex")
  public static let codexCommand = "\(keyPrefix)cli.codexCommand"

  /// Whether Claude command was set by developer (not user-editable)
  /// Type: Bool (default: false)
  public static let claudeCommandLockedByDeveloper = "\(keyPrefix)cli.claudeCommandLocked"

  /// Whether Codex command was set by developer (not user-editable)
  /// Type: Bool (default: false)
  public static let codexCommandLockedByDeveloper = "\(keyPrefix)cli.codexCommandLocked"

  /// Extra environment variables applied to launched CLI processes
  /// Type: Data (JSON-encoded [CLIEnvironmentVariable])
  public static let cliEnvironmentVariables = "\(keyPrefix)cli.environmentVariables"

  /// Extra CLI arguments applied to Claude command invocations
  /// Type: String (shell-style arguments, default: "")
  public static let claudeCommandArgs = "\(keyPrefix)cli.claudeCommandArgs"

  /// Extra CLI arguments applied to Codex command invocations
  /// Type: String (shell-style arguments, default: "")
  public static let codexCommandArgs = "\(keyPrefix)cli.codexCommandArgs"

  /// Selected provider in side panel segmented control
  /// Type: String (default: "Claude")
  public static let selectedSidePanelProvider = "\(keyPrefix)sidepanel.selectedProvider"

  // MARK: - Stats Settings

  /// Selected provider in stats view segmented control
  /// Type: String (default: "Claude")
  public static let selectedStatsProvider = "\(keyPrefix)stats.selectedProvider"

  // MARK: - UI Settings

  /// Terminal font size in points
  /// Type: Double (default: 12.0)
  public static let terminalFontSize = "\(keyPrefix)terminal.fontSize"

  /// Terminal font family name
  /// Type: String (default: "SF Mono")
  public static let terminalFontFamily = "\(keyPrefix)terminal.fontFamily"

  /// Embedded terminal backend
  /// Type: Int (default: 0 = Ghostty)
  public static let terminalBackend = "\(keyPrefix)terminal.backend"

  /// Custom Ghostty config file path for embedded Ghostty terminals
  /// Type: String (default: "")
  public static let terminalGhosttyConfigPath = "\(keyPrefix)terminal.ghosttyConfigPath"

  /// Whether source editors show the CodeEdit minimap
  /// Type: Bool (default: false)
  public static let sourceEditorMinimapEnabled = "\(keyPrefix)editor.minimapEnabled"

  /// Whether source editors wrap long lines instead of using horizontal scrolling
  /// Type: Bool (default: true)
  public static let sourceEditorWrapLinesEnabled = "\(keyPrefix)editor.wrapLinesEnabled"

  /// Preferred presentation for git diffs from session cards
  /// Type: String (default: "inline")
  public static let diffDisplayMode = "\(keyPrefix)ui.diffDisplayMode"

  /// Preferred newline shortcut in the embedded terminal
  /// Type: Int (default: 0 = system/default)
  /// See: NewlineShortcut enum in EmbeddedTerminalView.swift
  public static let terminalNewlineShortcut = "\(keyPrefix)terminal.newlineShortcut"

  /// Preferred editor for Cmd+Click file paths in the terminal
  /// Type: Int (default: 0 = AgentHub editor)
  /// See: FileOpenEditor enum in ManagedLocalProcessTerminalView.swift
  public static let terminalFileOpenEditor = "\(keyPrefix)terminal.fileOpenEditor"

  /// Whether the auxiliary shell dock is visible
  /// Type: Bool (default: false)
  public static let auxiliaryShellVisible = "\(keyPrefix)hub.auxiliaryShellVisible"

  /// Whether the selected sessions panel is expanded
  /// Type: Bool (default: true)
  public static let selectedSessionsPanelExpanded = "\(keyPrefix)ui.selectedSessionsPanelExpanded"

  /// Selected sessions panel size mode (collapsed, small, medium, full)
  /// Type: Int (default: 1 = small)
  public static let selectedSessionsPanelSizeMode = "\(keyPrefix)ui.selectedSessionsPanelSizeMode"

  /// Whether the global session control panel hotkey is enabled
  /// Type: Bool (default: true)
  public static let globalSessionPanelEnabled = "\(keyPrefix)globalSessionPanel.enabled"

  /// Last frame for the global session control panel
  /// Type: String (NSStringFromRect, default: unset)
  public static let globalSessionPanelFrame = "\(keyPrefix)globalSessionPanel.frame"

  /// Last compact frame for the global session control panel
  /// Type: String (NSStringFromRect, default: unset)
  public static let globalSessionPanelCompactFrame = "\(keyPrefix)globalSessionPanel.compactFrame"

  /// Display mode for the global session control panel
  /// Type: Int (default: 0 = regular, 1 = compact)
  public static let globalSessionPanelDisplayMode = "\(keyPrefix)globalSessionPanel.displayMode"

  // MARK: - Feature Flags

  /// Whether smart mode (AI-powered orchestration planning) is enabled
  /// Type: Bool (default: false)
  public static let smartModeEnabled = "\(keyPrefix)features.smartModeEnabled"

  /// Whether the debug web preview Design/Code/Console panel is enabled.
  /// Inline source edit mode is always available.
  /// Type: Bool (default: false)
  public static let webPreviewDesignPanelEnabled = "\(keyPrefix)developer.webPreviewDesignPanelEnabled"

  /// Whether Edit Mode style changes with a proven CSS rule mapping write the
  /// file directly instead of batching to the session's agent.
  /// Type: Bool (default: true)
  public static let webPreviewDirectCSSWriteEnabled = "\(keyPrefix)features.webPreviewDirectCSSWrite"

  /// Whether SwiftUI previews are available in the iOS simulator side panel.
  /// The live simulator view remains available when this is disabled.
  /// Type: Bool (default: true)
  public static let simulatorPreviewsEnabled = "\(keyPrefix)features.simulatorPreviewsEnabled"

  /// Whether the simulator side panel automatically Build & Runs when Swift
  /// sources change and no injection-armed launch can hot-swap them.
  /// Type: Bool (default: true)
  public static let simulatorAutoRunOnAgentChanges = "\(keyPrefix)features.simulatorAutoRunOnAgentChanges"

  /// Whether the real Simulator.app window is kept hidden (⌘H-style, still
  /// running) while the side panel mirrors the device. Panel-mirrored runs
  /// also skip bringing Simulator.app to the foreground.
  /// Type: Bool (default: true)
  public static let simulatorHideSimulatorAppWhileMirroring = "\(keyPrefix)features.simulatorHideSimulatorAppWhileMirroring"

  /// Whether agent sessions launched in Xcode projects get the XcodeBuildMCP
  /// server (simulator build/run, UI automation, screenshots) configured.
  /// Type: Bool (default: true)
  public static let xcodeBuildMCPEnabled = "\(keyPrefix)features.xcodeBuildMCPEnabled"

  /// Inspector payload level used by debug web preview inspect flows
  /// Type: String (default: "regular")
  public static let webPreviewInspectorDataLevel = "\(keyPrefix)developer.webPreviewInspectorDataLevel"

  /// Width of the side panel (diff, plan, web preview, GitHub) in the single-session layout
  /// Type: Double (default: 700)
  public static let sidePanelWidth = "\(keyPrefix)ui.sidePanelWidth"

  /// Width of the file tree sidebar inside FileExplorerView
  /// Type: Double (default: 240)
  public static let fileExplorerSidebarWidth = "\(keyPrefix)ui.fileExplorerSidebarWidth"

  /// Width of the inner inspector rail inside WebPreviewView
  /// Type: Double (default: 360)
  public static let webPreviewInspectorWidth = "\(keyPrefix)ui.webPreviewInspectorWidth"

  // MARK: - Worktree Settings

  /// Prefix applied to AI-generated launcher worktree branches.
  /// Type: String (default: "")
  public static let worktreeBranchPrefix = "\(keyPrefix)worktree.generatedBranchPrefix"

  /// How worktree sessions are grouped in module-oriented UI.
  /// Type: String (default: WorktreeDisplayMode.parent.rawValue)
  public static let worktreeDisplayMode = "\(keyPrefix)worktree.displayMode"

  // MARK: - Theme Settings

  /// Selected color theme name
  /// Type: String (default: "neutral")
  public static let selectedTheme = "\(keyPrefix)theme.selected"

  /// Last non-Ghostty color theme selected before switching to the Ghostty terminal backend
  /// Type: String (default: unset)
  public static let previousNonGhosttyTheme = "\(keyPrefix)theme.previousNonGhostty"

  /// Custom primary color hex value
  /// Type: String (default: "#7C3AED")
  public static let customPrimaryHex = "\(keyPrefix)theme.customPrimaryHex"

  /// Custom secondary color hex value
  /// Type: String (default: "#FFB000")
  public static let customSecondaryHex = "\(keyPrefix)theme.customSecondaryHex"

  /// Custom tertiary color hex value
  /// Type: String (default: "#64748B")
  public static let customTertiaryHex = "\(keyPrefix)theme.customTertiaryHex"

  /// Active YAML theme primary color hex value cache
  /// Type: String (default: unset)
  public static let yamlPrimaryHex = "\(keyPrefix)theme.yamlPrimaryHex"

  /// Active YAML theme secondary color hex value cache
  /// Type: String (default: unset)
  public static let yamlSecondaryHex = "\(keyPrefix)theme.yamlSecondaryHex"

  /// Active YAML theme tertiary color hex value cache
  /// Type: String (default: unset)
  public static let yamlTertiaryHex = "\(keyPrefix)theme.yamlTertiaryHex"

  /// Active YAML theme light appearance primary color hex value cache
  /// Type: String (default: unset)
  public static let yamlLightPrimaryHex = "\(keyPrefix)theme.yamlLightPrimaryHex"

  /// Active YAML theme light appearance secondary color hex value cache
  /// Type: String (default: unset)
  public static let yamlLightSecondaryHex = "\(keyPrefix)theme.yamlLightSecondaryHex"

  /// Active YAML theme light appearance tertiary color hex value cache
  /// Type: String (default: unset)
  public static let yamlLightTertiaryHex = "\(keyPrefix)theme.yamlLightTertiaryHex"

  /// Active YAML theme dark appearance primary color hex value cache
  /// Type: String (default: unset)
  public static let yamlDarkPrimaryHex = "\(keyPrefix)theme.yamlDarkPrimaryHex"

  /// Active YAML theme dark appearance secondary color hex value cache
  /// Type: String (default: unset)
  public static let yamlDarkSecondaryHex = "\(keyPrefix)theme.yamlDarkSecondaryHex"

  /// Active YAML theme dark appearance tertiary color hex value cache
  /// Type: String (default: unset)
  public static let yamlDarkTertiaryHex = "\(keyPrefix)theme.yamlDarkTertiaryHex"

  /// Installed bundled theme version for a given theme name
  /// Type: String (default: unset)
  /// Usage: `UserDefaults.standard.string(forKey: AgentHubDefaults.installedBundledThemeVersion(for: "sentry"))`
  public static func installedBundledThemeVersion(for themeName: String) -> String {
    "\(keyPrefix)theme.installedVersion.\(themeName)"
  }

  // MARK: - Migration

  /// Legacy keys mapping for migration
  private static let legacyKeyMappings: [String: String] = [
    "CLISessionsShowLastMessage": showLastMessage,
    "CLISessionsApprovalTimeout": approvalTimeout,
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

    // Migrate old "claude" default theme to "neutral"
    let themeMigrationKey = "\(keyPrefix)migration.themeDefaultMigrated"
    if !defaults.bool(forKey: themeMigrationKey) {
      let current = defaults.string(forKey: selectedTheme)
      if current == "claude" || current == nil {
        defaults.set("neutral", forKey: selectedTheme)
      }
      defaults.set(true, forKey: themeMigrationKey)
    }
  }
}
