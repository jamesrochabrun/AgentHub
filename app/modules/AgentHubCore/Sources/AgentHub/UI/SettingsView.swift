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

  @AppStorage(AgentHubDefaults.terminalFontSize)
  private var terminalFontSize: Double = 12

  @AppStorage(AgentHubDefaults.terminalFontFamily)
  private var terminalFontFamily: String = "SF Mono"

  @AppStorage(AgentHubDefaults.sourceEditorMinimapEnabled)
  private var sourceEditorMinimapEnabled: Bool = false

  @AppStorage(AgentHubDefaults.sourceEditorWrapLinesEnabled)
  private var sourceEditorWrapLinesEnabled: Bool = true

  @AppStorage(AgentHubDefaults.terminalNewlineShortcut)
  private var newlineShortcutRawValue: Int = NewlineShortcut.system.rawValue

  @AppStorage(AgentHubDefaults.terminalFileOpenEditor)
  private var fileOpenEditorRawValue: Int = FileOpenEditor.agentHub.rawValue

  @AppStorage(AgentHubDefaults.notificationSoundsEnabled)
  private var notificationSoundsEnabled: Bool = true

  @AppStorage(AgentHubDefaults.pushNotificationsEnabled)
  private var pushNotificationsEnabled: Bool = true

  @AppStorage(ClaudeHookInstaller.enabledKey)
  private var claudeApprovalHooksEnabled: Bool = true

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
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @AppStorage(AgentHubDefaults.selectedTheme) private var selectedThemeId: String = "singularity.yaml"
  private let defaultThemeId = "singularity.yaml"
  private let bundledYAMLThemeFileIds = ["sentry.yaml", "rigel.yaml", "vela.yaml", "antares.yaml", "singularity.yaml", "nebula.yaml", "helios.yaml"]
  private let terminalFontFamilies = [
    "SF Mono",
    "JetBrains Mono",
    "GeistMono",
    "Fira Code",
    "Cascadia Mono",
    "Source Code Pro",
    "Menlo",
    "Monaco",
    "Courier New",
  ]
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

      WorktreeSettingsView()
        .tabItem {
          Label("Worktrees", systemImage: "arrow.triangle.branch")
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

  @ViewBuilder
  private var settingsBackground: some View {
    if runtimeTheme?.hasCustomBackgrounds == true {
      Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
    } else {
      Color.clear
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

      Section("Claude Code integration") {
        settingsToggle(
          title: "Enable approval hooks",
          description: "Detects pending Edit/Bash/etc. approvals in real time. Installs a hook into each monitored project's .claude/settings.local.json (gitignored) only while AgentHub is actively watching the session.",
          isOn: $claudeApprovalHooksEnabled
        )
        .onChange(of: claudeApprovalHooksEnabled) { _, newValue in
          guard let provider = agentHub else { return }
          let installer = provider.claudeHookInstaller
          let claudeVM = provider.claudeSessionsViewModel
          Task {
            await installer.setEnabled(newValue)
            // Re-enable: trigger a fresh sync for the currently tracked repos
            // (setEnabled intentionally doesn't know about the repo list).
            if newValue {
              await MainActor.run {
                var paths: Set<String> = []
                for repo in claudeVM.selectedRepositories {
                  paths.insert(repo.path)
                  for worktree in repo.worktrees { paths.insert(worktree.path) }
                }
                Task { await installer.syncInstalledPaths(paths) }
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
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

    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
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
        Picker("Font", selection: $terminalFontFamily) {
          ForEach(terminalFontFamilies, id: \.self) { family in
            Text(family)
              .font(.custom(family, size: 13))
              .tag(family)
          }
        }

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

        Picker("Open files with", selection: $fileOpenEditorRawValue) {
          ForEach(FileOpenEditor.allCases, id: \.rawValue) { editor in
            Text(editor.label).tag(editor.rawValue)
          }
        }
      }

      Section("Editor") {
        settingsToggle(
          title: "Show code editor minimap",
          description: "Display the CodeEdit minimap in the session editor and web preview source editors",
          isOn: $sourceEditorMinimapEnabled
        )

        settingsToggle(
          title: "Wrap long lines",
          description: "Soft-wrap long lines instead of using horizontal scrolling in source editors",
          isOn: $sourceEditorWrapLinesEnabled
        )
      }

      Section {
        Picker("Theme", selection: themeSelectionBinding) {
          ForEach(bundledYAMLThemeFileIds, id: \.self) { fileId in
            Text(yamlThemeDisplayName(fileId)).tag(fileId)
          }
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
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
  }

#if DEBUG
  private var developerSettingsForm: some View {
    Form {
      Section("AI Features") {
        settingsToggle(
          title: "Smart mode",
          description: "Use AI to plan and orchestrate multi-session launches",
          isOn: $smartModeEnabled
        )
      }

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
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
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
        if let matchedFileId = matchingBundledYAMLFileId(for: selectedThemeId) {
          return matchedFileId
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
    if matchingBundledYAMLFileId(for: selectedThemeId) != nil {
      await applyThemeSelection(selectedThemeId)
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

    // Handle bundled YAML themes
    let fileId = matchingBundledYAMLFileId(for: selection) ?? selection
    await themeManager.discoverThemes()

    if let yamlTheme = themeManager.availableYAMLThemes.first(where: { $0.id == fileId }),
       let fileURL = yamlTheme.fileURL {
      try? await themeManager.loadTheme(fileURL: fileURL)
      selectedThemeId = yamlTheme.id
      return
    }

    let themeURL = ThemeManager.themesDirectory().appendingPathComponent(fileId)
    if FileManager.default.fileExists(atPath: themeURL.path) {
      try? await themeManager.loadTheme(fileURL: themeURL)
      selectedThemeId = fileId
      return
    }

    selectedThemeId = defaultThemeId
    themeManager.loadBuiltInTheme(.neutral)
  }

  private func matchingBundledYAMLFileId(for value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return bundledYAMLThemeFileIds.first { fileId in
      let baseName = fileId.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")
      return normalized == baseName || normalized == fileId || normalized == baseName + ".yml"
    }
  }

  private func yamlThemeDisplayName(_ fileId: String) -> String {
    let baseName = fileId.replacingOccurrences(of: ".yaml", with: "").replacingOccurrences(of: ".yml", with: "")
    return baseName.prefix(1).uppercased() + baseName.dropFirst()
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
