//
//  SettingsView.swift
//  AgentHub
//
//  Settings panel for app configuration.
//

import SwiftUI
import Canvas

#if canImport(AppKit)
import AppKit
#endif

public struct SettingsView: View {
  @Environment(\.agentHub) private var agentHub
  @State private var aiConfigViewModel = AIConfigSettingsViewModel()
  @State private var isClaudeConfigurationExpanded = true
  @State private var isCodexConfigurationExpanded = true
  @State private var pendingTerminalBackend: EmbeddedTerminalBackend?
  @State private var showTerminalBackendRelaunchAlert = false
  @State private var cliEnvironmentVariables = CLIEnvironmentOverrides.variables

  @AppStorage(AgentHubDefaults.smartModeEnabled)
  private var smartModeEnabled: Bool = false

  @AppStorage(AgentHubDefaults.terminalFontSize)
  private var terminalFontSize: Double = 12

  @AppStorage(AgentHubDefaults.terminalFontFamily)
  private var terminalFontFamily: String = "SF Mono"

  @AppStorage(AgentHubDefaults.terminalBackend)
  private var terminalBackendRawValue: Int = EmbeddedTerminalBackend.regular.rawValue

  @AppStorage(AgentHubDefaults.terminalGhosttyConfigPath)
  private var terminalGhosttyConfigPath: String = ""

  @AppStorage(AgentHubDefaults.sourceEditorMinimapEnabled)
  private var sourceEditorMinimapEnabled: Bool = true

  @AppStorage(AgentHubDefaults.sourceEditorWrapLinesEnabled)
  private var sourceEditorWrapLinesEnabled: Bool = true

  @AppStorage(AgentHubDefaults.diffDisplayMode)
  private var diffDisplayModeRawValue: String = DiffDisplayMode.inline.rawValue

  @AppStorage(AgentHubDefaults.terminalNewlineShortcut)
  private var newlineShortcutRawValue: Int = NewlineShortcut.system.rawValue

  @AppStorage(AgentHubDefaults.terminalFileOpenEditor)
  private var fileOpenEditorRawValue: Int = FileOpenEditor.agentHub.rawValue

  @AppStorage(AgentHubDefaults.notificationSoundsEnabled)
  private var notificationSoundsEnabled: Bool = true

  @AppStorage(AgentHubDefaults.pushNotificationsEnabled)
  private var pushNotificationsEnabled: Bool = true

  @AppStorage(AgentHubDefaults.globalSessionPanelEnabled)
  private var globalSessionPanelEnabled: Bool = true

  @AppStorage(AgentHubDefaults.simulatorPreviewsEnabled)
  private var simulatorPreviewsEnabled: Bool = true

  @AppStorage(AgentHubDefaults.simulatorAutoRunOnAgentChanges)
  private var simulatorAutoRunOnAgentChanges: Bool = true

  @AppStorage(AgentHubDefaults.simulatorHideSimulatorAppWhileMirroring)
  private var hideSimulatorAppWhileMirroring: Bool = true

  @AppStorage(AgentHubDefaults.xcodeBuildMCPEnabled)
  private var xcodeBuildMCPEnabled: Bool = true

  @State private var xcodeBuildMCPToolingAvailable = true

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

  @AppStorage(AgentHubDefaults.claudeCommandArgs)
  private var claudeCommandArgs: String = ""

  @AppStorage(AgentHubDefaults.codexCommandArgs)
  private var codexCommandArgs: String = ""

  @AppStorage(AgentHubDefaults.webPreviewInspectorDataLevel)
  private var webPreviewInspectorDataLevelRawValue: String = ElementInspectorDataLevel.regular.rawValue

  @AppStorage(AgentHubDefaults.webPreviewDesignPanelEnabled)
  private var webPreviewDesignPanelEnabled: Bool = false

  @AppStorage(AgentHubDefaults.webPreviewDirectCSSWriteEnabled)
  private var webPreviewDirectCSSWriteEnabled: Bool = true

  @Environment(ThemeManager.self) private var themeManager
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @State private var selectedThemeId: String = Self.initialSelectedThemeId()
  @State private var themeSelectionTask: Task<Void, Never>?
  @State private var applyingThemeSelectionId: String?
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

  private var activeTerminalBackend: EmbeddedTerminalBackend {
    agentHub?.terminalBackend ?? .storedPreference
  }

  private var defaultThemeId: String {
    ThemeSelectionPolicy.defaultThemeId(for: activeTerminalBackend)
  }

  private var bundledYAMLThemeFileIds: [String] {
    ThemeSelectionPolicy.bundledYAMLThemeFileIds(for: activeTerminalBackend)
  }

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
      cliEnvironmentVariables = CLIEnvironmentOverrides.variables
      await ensureSupportedThemeSelection()
      await aiConfigViewModel.load(service: agentHub?.aiConfigService)
    }
    .onChange(of: cliEnvironmentVariables) { _, newValue in
      CLIEnvironmentOverrides.save(newValue)
    }
    .onChange(of: terminalGhosttyConfigPath) { _, _ in
      themeManager.refreshGhosttyUserBackground(backend: activeTerminalBackend)
    }
    .onDisappear {
      themeSelectionTask?.cancel()
      themeSelectionTask = nil
      applyingThemeSelectionId = nil
    }
    .alert(
      "Relaunch AgentHub?",
      isPresented: $showTerminalBackendRelaunchAlert,
      presenting: pendingTerminalBackend
    ) { backend in
      Button("Cancel", role: .cancel) {
        pendingTerminalBackend = nil
      }
      Button("Relaunch") {
        terminalBackendRawValue = backend.rawValue
        pendingTerminalBackend = nil
        agentHub?.relaunchApplication()
      }
    } message: { backend in
      Text(
        "Switching to \(backend.label) requires relaunching AgentHub. Running terminals will be closed during relaunch."
      )
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

      Section("Global session control panel") {
        settingsToggle(
          title: "Enable global shortcut",
          description: "Open a floating panel of monitored Claude and Codex sessions from anywhere",
          isOn: $globalSessionPanelEnabled
        )
        .onChange(of: globalSessionPanelEnabled) { _, newValue in
          agentHub?.globalSessionControlPanelCoordinator.setEnabled(newValue)
        }

        HStack {
          Text("Shortcut")
          Spacer()
          Text(GlobalHotKey.sessionControlPanelDefault.displayString)
            .font(.primaryCaption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }

        if let error = agentHub?.globalSessionControlPanelCoordinator.registrationErrorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundColor(.orange)
        }
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

      Section("iOS Simulator") {
        settingsToggle(
          title: "Enable SwiftUI previews",
          description: "Show the Previews tab in the simulator side panel and watch Swift source changes while it is enabled.",
          isOn: $simulatorPreviewsEnabled
        )

        settingsToggle(
          title: "Auto Build & Run on code changes",
          description: "While the simulator panel is open, rebuild and relaunch automatically when Swift sources change and hot reload isn't armed to swap them in place.",
          isOn: $simulatorAutoRunOnAgentChanges
        )

        settingsToggle(
          title: "Hide Simulator.app while mirroring",
          description: "Keep the real Simulator window hidden (still running, ⌘H style) while the side panel mirrors the device, and don't bring it forward on panel Build & Run. Turn off to see both.",
          isOn: $hideSimulatorAppWhileMirroring
        )

        settingsToggle(
          title: "Agent simulator tools (XcodeBuildMCP)",
          description: "Give agent sessions in Xcode projects the XcodeBuildMCP server so they can build, run, and verify changes in the simulator. Uses a globally installed xcodebuildmcp, or fetches a pinned version via npx (requires Node.js).",
          isOn: $xcodeBuildMCPEnabled
        )
        if xcodeBuildMCPEnabled && !xcodeBuildMCPToolingAvailable {
          Label(
            "Node.js not found — Xcode project sessions will launch without simulator tools until Node.js or xcodebuildmcp is installed.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundColor(.orange)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
    .task {
      xcodeBuildMCPToolingAvailable = await Task.detached {
        XcodeBuildMCPPreflight.nodeToolingAvailable()
      }.value
    }
  }

  private var configurationSettingsForm: some View {
    Form {
      Section("CLI Configuration") {
        providerConfigurationSection(
          title: "Claude",
          provider: .claude,
          isExpanded: $isClaudeConfigurationExpanded,
          command: $claudeCommand,
          commandArgs: $claudeCommandArgs,
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
          commandArgs: $codexCommandArgs,
          locked: codexCommandLocked,
          installed: CLIDetectionService.isCodexInstalled()
        ) {
          CodexAIConfigView(viewModel: aiConfigViewModel)
        }
      }

      Section("Environment Variables") {
        CLIEnvironmentVariablesEditor(variables: $cliEnvironmentVariables)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
  }

  private var appearanceSettingsForm: some View {
    Form {
      Section("Layout") {
        Picker("Diff display", selection: $diffDisplayModeRawValue) {
          ForEach(DiffDisplayMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
      }

      Section("Terminal") {
        #if DEBUG
        Picker("Terminal", selection: terminalBackendSelectionBinding) {
          ForEach(EmbeddedTerminalBackend.allCases, id: \.rawValue) { backend in
            Text(backend.label).tag(backend.rawValue)
          }
        }

        if activeTerminalBackend == .ghostty {
          ghosttyConfigFileSetting
        }
        #endif

        if activeTerminalBackend != .ghostty {
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

          Picker("Open files with", selection: $fileOpenEditorRawValue) {
            ForEach(FileOpenEditor.allCases, id: \.rawValue) { editor in
              Text(editor.label).tag(editor.rawValue)
            }
          }
        }

        Picker("Newline shortcut", selection: $newlineShortcutRawValue) {
          ForEach(NewlineShortcut.allCases, id: \.rawValue) { shortcut in
            Text(shortcut.label).tag(shortcut.rawValue)
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

      if activeTerminalBackend != .ghostty {
        Section {
          HStack(spacing: 10) {
            Picker("Theme", selection: themeSelectionBinding) {
              ForEach(bundledYAMLThemeFileIds, id: \.self) { fileId in
                Text(yamlThemeDisplayName(fileId)).tag(fileId)
              }
            }

            if applyingThemeSelectionId != nil {
              HStack(spacing: 6) {
                ProgressView()
                  .controlSize(.small)
                Text("Applying...")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .transition(.opacity)
            }
          }

          Button {
            Task { await themeManager.discoverThemes() }
          } label: {
            Label("Refresh themes", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.link)
          .disabled(applyingThemeSelectionId != nil)
        } header: {
          Text("Theme")
        } footer: {
          if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            Text("AgentHub v\(appVersion)")
              .font(.caption)
          }
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
          title: "Enable web preview design panel",
          description: "Uses the side-panel Design/Code/Console editor instead of the inline toolbar",
          isOn: $webPreviewDesignPanelEnabled
        )

        settingsToggle(
          title: "Direct CSS writes in Edit Mode",
          description: "Write style edits straight to the stylesheet when the exact rule is proven; otherwise they still apply via the agent",
          isOn: $webPreviewDirectCSSWriteEnabled
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
        Text("Inline source edit tools are always available. This toggle enables the developer side panel.")
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
    commandArgs: Binding<String>,
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

          VStack(alignment: .leading, spacing: 6) {
            Text("Extra arguments")
              .font(.caption)
              .foregroundColor(.secondary)

            TextField("e.g. --api-mode enterprise", text: commandArgs)
              .textFieldStyle(.roundedBorder)

            Text("Arguments applied to each CLI launch.")
              .font(.caption)
              .foregroundColor(.secondary)
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
      get: { currentThemeSelectionId },
      set: { newValue in
        guard newValue != currentThemeSelectionId else { return }
        let requestedThemeId = newValue
        selectedThemeId = requestedThemeId
        applyingThemeSelectionId = requestedThemeId
        themeSelectionTask?.cancel()
        themeSelectionTask = Task {
          try? await Task.sleep(for: .milliseconds(150))
          guard !Task.isCancelled else { return }
          await applyThemeSelection(requestedThemeId)
          guard !Task.isCancelled, applyingThemeSelectionId == requestedThemeId else { return }
          applyingThemeSelectionId = nil
          themeSelectionTask = nil
        }
      }
    )
  }

  private var terminalBackendSelectionBinding: Binding<Int> {
    Binding(
      get: { terminalBackendRawValue },
      set: { newValue in
        let requestedBackend = EmbeddedTerminalBackend(rawValue: newValue) ?? .ghostty
        guard requestedBackend != activeTerminalBackend else {
          terminalBackendRawValue = requestedBackend.rawValue
          pendingTerminalBackend = nil
          return
        }

        pendingTerminalBackend = requestedBackend
        showTerminalBackendRelaunchAlert = true
      }
    )
  }

  private var ghosttyConfigFileSetting: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Ghostty config file")

      HStack(spacing: 8) {
        TextField("Optional config file path", text: $terminalGhosttyConfigPath)
          .textFieldStyle(.roundedBorder)

        Button("Choose…", action: chooseGhosttyConfigFile)

        Button("Clear") {
          terminalGhosttyConfigPath = ""
        }
        .disabled(terminalGhosttyConfigPath.isEmpty)
      }

      if ghosttyConfigPathIsInvalid {
        Label("File not found or not readable — the setting is ignored.", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundColor(.orange)
      }

      Text("Layered on top of your Ghostty configuration, for AgentHub terminals only. The app backdrop updates immediately; fresh terminal processes may require relaunch.")
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private var ghosttyConfigPathIsInvalid: Bool {
    let trimmed = terminalGhosttyConfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let expandedPath = (trimmed as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          FileManager.default.isReadableFile(atPath: expandedPath) else {
      return true
    }
    return false
  }

  private func chooseGhosttyConfigFile() {
    #if canImport(AppKit)
    let panel = NSOpenPanel()
    panel.title = "Choose Ghostty Config"
    panel.message = "Choose a Ghostty configuration file for embedded Ghostty terminals."
    panel.prompt = "Choose"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false

    let expandedPath = (terminalGhosttyConfigPath as NSString).expandingTildeInPath
    if !expandedPath.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: expandedPath).deletingLastPathComponent()
    }

    if panel.runModal() == .OK, let url = panel.url {
      terminalGhosttyConfigPath = url.path
    }
    #endif
  }

  private func ensureSupportedThemeSelection() async {
    let themeId = ThemeSelectionPolicy.canonicalThemeId(
      for: selectedThemeId,
      backend: activeTerminalBackend
    ) ?? defaultThemeId
    let appliedThemeId = await themeManager.applySelection(themeId, backend: activeTerminalBackend)
    selectedThemeId = appliedThemeId
  }

  private func applyThemeSelection(_ selection: String) async {
    let appliedThemeId = await themeManager.applySelection(selection, backend: activeTerminalBackend)
    selectedThemeId = appliedThemeId
  }

  private func matchingBundledYAMLFileId(for value: String) -> String? {
    ThemeSelectionPolicy.matchingBundledYAMLFileId(for: value, in: bundledYAMLThemeFileIds)
  }

  private static func initialSelectedThemeId() -> String {
    UserDefaults.standard.string(forKey: AgentHubDefaults.selectedTheme) ?? "singularity.yaml"
  }

  private var currentThemeSelectionId: String {
    if let matchedFileId = matchingBundledYAMLFileId(for: selectedThemeId) {
      return matchedFileId
    }
    if activeTerminalBackend == .regular, let appTheme = AppTheme(rawValue: selectedThemeId) {
      return appTheme.rawValue
    }
    return defaultThemeId
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
