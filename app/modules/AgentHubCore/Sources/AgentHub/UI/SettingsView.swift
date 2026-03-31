//
//  SettingsView.swift
//  AgentHub
//
//  Settings panel for app configuration.
//

import SwiftUI
import Canvas

public struct SettingsView: View {
  @Environment(\.agentHub) private var agentHub
  @State private var aiConfigViewModel = AIConfigSettingsViewModel()
  @State private var isClaudeConfigurationExpanded = true
  @State private var isCodexConfigurationExpanded = true

  @AppStorage(AgentHubDefaults.smartModeEnabled)
  private var smartModeEnabled: Bool = false

  @AppStorage(AgentHubDefaults.flatSessionLayout)
  private var flatSessionLayout: Bool = false

  @AppStorage(AgentHubDefaults.fileExplorerAlwaysModal)
  private var fileExplorerAlwaysModal: Bool = false

  @AppStorage(AgentHubDefaults.terminalFontSize)
  private var terminalFontSize: Double = 12

  @AppStorage(AgentHubDefaults.terminalNewlineShortcut)
  private var newlineShortcutRawValue: Int = NewlineShortcut.system.rawValue

  @AppStorage(AgentHubDefaults.notificationSoundsEnabled)
  private var notificationSoundsEnabled: Bool = true

  @AppStorage(AgentHubDefaults.pushNotificationsEnabled)
  private var pushNotificationsEnabled: Bool = true

  @AppStorage(AgentHubDefaults.claudeCommand)
  private var claudeCommand: String = "claude"

  @AppStorage(AgentHubDefaults.codexCommand)
  private var codexCommand: String = "codex"

  @AppStorage(AgentHubDefaults.claudeCommandLockedByDeveloper)
  private var claudeCommandLocked: Bool = false

  @AppStorage(AgentHubDefaults.codexCommandLockedByDeveloper)
  private var codexCommandLocked: Bool = false

  @AppStorage(AgentHubDefaults.webPreviewInspectorDataLevel)
  private var webPreviewInspectorDataLevelRawValue: String = ElementInspectorDataLevel.regular.rawValue

  @AppStorage(AgentHubDefaults.webPreviewAdvancedEditingEnabled)
  private var webPreviewAdvancedEditingEnabled: Bool = true

  @Environment(ThemeManager.self) private var themeManager
  @AppStorage(AgentHubDefaults.selectedTheme) private var selectedThemeId: String = "neutral"
  private let defaultThemeId = "neutral"
  private let sentryThemeFileId = "sentry.yaml"
  private let webPreviewInspectorDataLevels: [ElementInspectorDataLevel] = [.regular, .full]

  public init() {}

  public var body: some View {
    TabView {
      generalSettingsForm
        .tabItem {
          Label("General", systemImage: "gearshape")
        }

      configurationSettingsForm
        .tabItem {
          Label("Configuration", systemImage: "sparkles")
        }

      appearanceSettingsForm
        .tabItem {
          Label("Appearance", systemImage: "paintpalette")
        }

#if DEBUG
      developerSettingsForm
        .tabItem {
          Label("Developer", systemImage: "hammer")
        }
#endif
    }
    .frame(width: 700, height: 620)
    .task {
      await ensureSupportedThemeSelection()
      await aiConfigViewModel.load(service: agentHub?.aiConfigService)
    }
  }

  private var generalSettingsForm: some View {
    Form {
      Section("Notifications") {
        settingsToggle(
          title: "Notification sounds",
          description: "Play a sound when tools require approval",
          isOn: $notificationSoundsEnabled
        )

        settingsToggle(
          title: "Push notifications",
          description: "Show a notification banner when tools require approval",
          isOn: $pushNotificationsEnabled
        )
      }

      Section("Features") {
        settingsToggle(
          title: "File explorer always modal",
          description: "Open file explorer as a floating window instead of a side panel",
          isOn: $fileExplorerAlwaysModal
        )
      }
    }
    .formStyle(.grouped)
  }

  private var configurationSettingsForm: some View {
    Form {
      Section("CLI Configuration") {
        providerConfigurationSection(
          title: "Claude",
          provider: .claude,
          isExpanded: $isClaudeConfigurationExpanded,
          command: $claudeCommand,
          locked: claudeCommandLocked,
          installed: CLIDetectionService.isClaudeInstalled()
        ) {
          ClaudeAIConfigView(viewModel: aiConfigViewModel)
        }

        providerConfigurationSection(
          title: "Codex",
          provider: .codex,
          isExpanded: $isCodexConfigurationExpanded,
          command: $codexCommand,
          locked: codexCommandLocked,
          installed: CLIDetectionService.isCodexInstalled()
        ) {
          CodexAIConfigView(viewModel: aiConfigViewModel)
        }
      }

      Section("AI Features") {
        settingsToggle(
          title: "Smart mode",
          description: "Use AI to plan and orchestrate multi-session launches",
          isOn: $smartModeEnabled
        )
      }
    }
    .formStyle(.grouped)
  }

  private var appearanceSettingsForm: some View {
    Form {
      Section("Layout") {
        settingsToggle(
          title: "Flat session layout",
          description: "Show all sessions without per-repository sections",
          isOn: $flatSessionLayout
        )
      }

      Section("Terminal") {
        Stepper(value: $terminalFontSize, in: 8...24, step: 1) {
          HStack {
            Text("Font size")
            Spacer()
            Text("\(Int(terminalFontSize)) pt")
              .foregroundColor(.secondary)
              .monospacedDigit()
          }
        }

        Picker("Newline shortcut", selection: $newlineShortcutRawValue) {
          ForEach(NewlineShortcut.allCases, id: \.rawValue) { shortcut in
            Text(shortcut.label).tag(shortcut.rawValue)
          }
        }
      }

      Section {
        Picker("Theme", selection: themeSelectionBinding) {
          Text("Default").tag(AppTheme.neutral.rawValue)
          Text("Claude").tag(AppTheme.claude.rawValue)
          Text("Codex").tag(AppTheme.codex.rawValue)
          Text("Sentry").tag(sentryThemeFileId)
        }

        Button {
          Task { await themeManager.discoverThemes() }
        } label: {
          Label("Refresh themes", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.link)
      } header: {
        Text("Theme")
      } footer: {
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
          Text("AgentHub v\(appVersion)")
            .font(.caption)
        }
      }
    }
    .formStyle(.grouped)
  }

#if DEBUG
  private var developerSettingsForm: some View {
    Form {
      Section {
        settingsToggle(
          title: "Enable web preview design tools",
          description: "Shows the debug-only Design/Code/Console editing surface in web preview",
          isOn: $webPreviewAdvancedEditingEnabled
        )

        Picker("Inspector payload", selection: webPreviewInspectorDataLevelBinding) {
          ForEach(webPreviewInspectorDataLevels, id: \.rawValue) { level in
            Text(level.settingsLabel).tag(level)
          }
        }

        Text(selectedWebPreviewInspectorDataLevel.settingsDescription)
          .font(.caption)
          .foregroundColor(.secondary)
      } header: {
        Text("Web Preview")
      } footer: {
        Text("These controls only affect debug builds. Production users never see the design editing surface. Source edit mode still upgrades capture to Full when enabled.")
      }
    }
    .formStyle(.grouped)
  }
#endif

  private func providerConfigurationSection<Content: View>(
    title: String,
    provider: SessionProviderKind,
    isExpanded: Binding<Bool>,
    command: Binding<String>,
    locked: Bool,
    installed: Bool,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          isExpanded.wrappedValue.toggle()
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)

          Text(title)
            .foregroundColor(Color.brandPrimary(for: provider))

          Spacer()

          if installed {
            Label("Installed", systemImage: "checkmark.circle.fill")
              .foregroundColor(.green)
              .font(.caption)
          } else {
            Label("Not Installed", systemImage: "xmark.circle.fill")
              .foregroundColor(.secondary)
              .font(.caption)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded.wrappedValue {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Command")
              .font(.caption)
              .foregroundColor(.secondary)

            HStack(spacing: 8) {
              TextField(title.lowercased(), text: command)
                .textFieldStyle(.roundedBorder)
                .disabled(locked)

              if locked {
                Image(systemName: "lock.fill")
                  .foregroundColor(.secondary)
                  .font(.caption)
              }
            }
          }

          content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 20)
        .padding(.top, 4)
      }
    }
    .padding(.vertical, 4)
  }

  private func settingsToggle(
    title: String,
    description: String,
    isOn: Binding<Bool>
  ) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(description)
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }

  private var themeSelectionBinding: Binding<String> {
    Binding(
      get: {
        if isSentryThemeId(selectedThemeId) {
          return sentryThemeFileId
        }
        if let appTheme = AppTheme(rawValue: selectedThemeId) {
          return appTheme.rawValue
        }
        return defaultThemeId
      },
      set: { newValue in
        Task {
          await applyThemeSelection(newValue)
        }
      }
    )
  }

  private func ensureSupportedThemeSelection() async {
    if isSentryThemeId(selectedThemeId) {
      await applyThemeSelection(sentryThemeFileId)
      return
    }

    if AppTheme(rawValue: selectedThemeId) != nil {
      return
    }

    selectedThemeId = defaultThemeId
    themeManager.loadBuiltInTheme(.neutral)
  }

  private func applyThemeSelection(_ selection: String) async {
    // Handle built-in themes
    if let appTheme = AppTheme(rawValue: selection) {
      selectedThemeId = appTheme.rawValue
      themeManager.loadBuiltInTheme(appTheme)
      return
    }

    // Handle Sentry YAML theme
    await themeManager.discoverThemes()

    if let sentryTheme = themeManager.availableYAMLThemes.first(where: isSentryTheme),
       let fileURL = sentryTheme.fileURL {
      try? await themeManager.loadTheme(fileURL: fileURL)
      selectedThemeId = sentryTheme.id
      return
    }

    let sentryURL = ThemeManager.themesDirectory().appendingPathComponent(sentryThemeFileId)
    if FileManager.default.fileExists(atPath: sentryURL.path) {
      try? await themeManager.loadTheme(fileURL: sentryURL)
      selectedThemeId = sentryThemeFileId
      return
    }

    selectedThemeId = defaultThemeId
    themeManager.loadBuiltInTheme(.neutral)
  }

  private func isSentryTheme(_ metadata: ThemeManager.ThemeMetadata) -> Bool {
    isSentryThemeId(metadata.id) || metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "sentry"
  }

  private func isSentryThemeId(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "sentry" || normalized == "sentry.yaml" || normalized == "sentry.yml"
  }

  private var selectedWebPreviewInspectorDataLevel: ElementInspectorDataLevel {
    ElementInspectorDataLevel(rawValue: webPreviewInspectorDataLevelRawValue) ?? .regular
  }

  private var webPreviewInspectorDataLevelBinding: Binding<ElementInspectorDataLevel> {
    Binding(
      get: { selectedWebPreviewInspectorDataLevel },
      set: { webPreviewInspectorDataLevelRawValue = $0.rawValue }
    )
  }
}

private extension ElementInspectorDataLevel {
  var settingsLabel: String {
    switch self {
    case .regular: "Regular"
    case .full: "Full"
    }
  }

  var settingsDescription: String {
    switch self {
    case .regular:
      "Legacy compact payload with the core styles and no DOM neighborhood context."
    case .full:
      "Expanded CSS capture with parent, sibling, and child context for deeper debugging."
    }
  }
}
