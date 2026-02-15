//
//  SettingsView.swift
//  AgentHub
//
//  Settings panel for app configuration.
//

import SwiftUI

public struct SettingsView: View {
  @AppStorage(AgentHubDefaults.notificationSoundsEnabled)
  private var notificationSoundsEnabled: Bool = true

  @AppStorage(AgentHubDefaults.claudeCommand)
  private var claudeCommand: String = "claude"

  @AppStorage(AgentHubDefaults.codexCommand)
  private var codexCommand: String = "codex"

  @AppStorage(AgentHubDefaults.claudeCommandLockedByDeveloper)
  private var claudeCommandLocked: Bool = false

  @AppStorage(AgentHubDefaults.codexCommandLockedByDeveloper)
  private var codexCommandLocked: Bool = false

  @EnvironmentObject private var themeManager: ThemeManager
  @AppStorage("selectedTheme") private var selectedThemeId: String = "claude"

  public init() {}

  public var body: some View {
    Form {
      Section("CLI Status") {
        DisclosureGroup {
          HStack {
            Text("Command:")
              .foregroundColor(.secondary)
            TextField("claude", text: $claudeCommand)
              .textFieldStyle(.roundedBorder)
              .disabled(claudeCommandLocked)
            if claudeCommandLocked {
              Image(systemName: "lock.fill")
                .foregroundColor(.secondary)
                .font(.caption)
            }
          }
          .padding(.vertical, 4)
        } label: {
          HStack {
            Text("Claude")
              .foregroundColor(Color.brandPrimary(for: .claude))
            Spacer()
            if CLIDetectionService.isClaudeInstalled() {
              Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            } else {
              Label("Not Installed", systemImage: "xmark.circle.fill")
                .foregroundColor(.secondary)
                .font(.caption)
            }
          }
        }

        DisclosureGroup {
          HStack {
            Text("Command:")
              .foregroundColor(.secondary)
            TextField("codex", text: $codexCommand)
              .textFieldStyle(.roundedBorder)
              .disabled(codexCommandLocked)
            if codexCommandLocked {
              Image(systemName: "lock.fill")
                .foregroundColor(.secondary)
                .font(.caption)
            }
          }
          .padding(.vertical, 4)
        } label: {
          HStack {
            Text("Codex")
              .foregroundColor(Color.brandPrimary(for: .codex))
            Spacer()
            if CLIDetectionService.isCodexInstalled() {
              Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
            } else {
              Label("Not Installed", systemImage: "xmark.circle.fill")
                .foregroundColor(.secondary)
                .font(.caption)
            }
          }
        }
      }

      Section {
        Toggle(isOn: $notificationSoundsEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Notification sounds")
            Text("Play a sound when tools require approval")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      } header: {
        Text("Notifications")
      }

      Section {
        Picker("Theme", selection: $selectedThemeId) {
          // Built-in themes
          ForEach(AppTheme.allCases) { theme in
            Text(theme.displayName).tag(theme.rawValue)
          }

          // YAML themes
          if !themeManager.availableYAMLThemes.isEmpty {
            Divider()
            ForEach(themeManager.availableYAMLThemes) { metadata in
              Text(metadata.name).tag(metadata.id)
            }
          }
        }
        .onChange(of: selectedThemeId) { _, newValue in
          Task {
            if let appTheme = AppTheme(rawValue: newValue) {
              themeManager.loadBuiltInTheme(appTheme)
            } else if let yamlTheme = themeManager.availableYAMLThemes.first(where: { $0.id == newValue }),
                      let fileURL = yamlTheme.fileURL {
              try? await themeManager.loadTheme(fileURL: fileURL)
            }
          }
        }

        HStack(spacing: 8) {
          Button("Import Theme...") {
            showThemeImportPanel()
          }

          Button("Open Themes Folder") {
            themeManager.openThemesFolder()
          }

          Button(action: {
            Task { await themeManager.discoverThemes() }
          }) {
            Image(systemName: "arrow.clockwise")
          }
          .help("Refresh theme list")
        }
      } header: {
        Text("Theme")
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Place .yaml theme files in ~/Library/Application Support/AgentHub/Themes/")
          if themeManager.currentTheme.isYAML {
            Text("✨ Theme changes are automatically reloaded")
              .foregroundColor(.green)
          }
        }
        .font(.caption)
      }
    }
    .formStyle(.grouped)
    .frame(width: 300, height: 500)
  }

  private func showThemeImportPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "yaml")!, .init(filenameExtension: "yml")!]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false

    guard panel.runModal() == .OK, let url = panel.url else { return }

    // Copy to themes directory
    let themesDir = ThemeManager.themesDirectory()
    let destination = themesDir.appendingPathComponent(url.lastPathComponent)

    do {
      try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)

      // Remove existing file if it exists
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }

      try FileManager.default.copyItem(at: url, to: destination)
      Task {
        await themeManager.discoverThemes()
        try? await themeManager.loadTheme(fileURL: destination)
        selectedThemeId = destination.lastPathComponent
      }
    } catch {
      // In a real app, show a proper error alert
      print("Failed to import theme: \(error)")
    }
  }
}
