//
//  SettingsView.swift
//  AgentHub
//
//  Settings panel for app configuration.
//

import SwiftUI

public struct SettingsView: View {
  @AppStorage(AgentHubDefaults.smartModeEnabled)
  private var smartModeEnabled: Bool = false

  @AppStorage(AgentHubDefaults.flatSessionLayout)
  private var flatSessionLayout: Bool = false

  @AppStorage(AgentHubDefaults.terminalFontSize)
  private var terminalFontSize: Double = 12

  @AppStorage(AgentHubDefaults.webServerEnabled)
  private var webServerEnabled: Bool = false

  #if DEBUG
  @AppStorage(AgentHubDefaults.webServerPort) private var webServerPort: Int = 8081
  #else
  @AppStorage(AgentHubDefaults.webServerPort) private var webServerPort: Int = 8080
  #endif

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

  @Environment(ThemeManager.self) private var themeManager
  @AppStorage(AgentHubDefaults.selectedTheme) private var selectedThemeId: String = "claude"
  private let defaultThemeId = "claude"
  private let sentryThemeFileId = "sentry.yaml"

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
        Toggle(isOn: $pushNotificationsEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Push notifications")
            Text("Show a notification banner when tools require approval")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      } header: {
        Text("Notifications")
      }

      Section("Features") {
        Toggle(isOn: $smartModeEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Smart mode")
            Text("Use AI to plan and orchestrate multi-session launches")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
        Toggle(isOn: $flatSessionLayout) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Flat session layout")
            Text("Show all sessions without per-repository sections")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
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
      }

      Section {
        Toggle(isOn: $webServerEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Web terminal")
            Text("Stream terminal sessions to a browser")
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }

        Stepper(value: $webServerPort, in: 1024...65535, step: 1) {
          HStack {
            Text("Port")
            Spacer()
            Text("\(webServerPort)")
              .foregroundColor(.secondary)
              .monospacedDigit()
          }
        }
        .disabled(!webServerEnabled)

        if webServerEnabled {
          let address = "http://\(localIPAddress()):\(webServerPort)"
          HStack {
            Text(address)
              .font(.caption)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            Spacer()
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(address, forType: .string)
            } label: {
              Image(systemName: "doc.on.doc")
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy address")
          }
          Text("Restart app to apply changes")
            .font(.caption2)
            .foregroundColor(.secondary)
        }
      } header: {
        Text("Web Terminal")
      }

      Section {
        Picker("Theme", selection: themeSelectionBinding) {
          Text("Default").tag(defaultThemeId)
          Text("Sentry").tag(sentryThemeFileId)
        }

        HStack(spacing: 8) {
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
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
          Text("AgentHub v\(appVersion)")
            .font(.caption)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 300, height: 580)
    .task {
      await ensureSupportedThemeSelection()
    }
  }

  private var themeSelectionBinding: Binding<String> {
    Binding(
      get: {
        isSentryThemeId(selectedThemeId) ? sentryThemeFileId : defaultThemeId
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

    if selectedThemeId != defaultThemeId {
      selectedThemeId = defaultThemeId
      themeManager.loadBuiltInTheme(.claude)
    }
  }

  private func applyThemeSelection(_ selection: String) async {
    if selection == defaultThemeId {
      selectedThemeId = defaultThemeId
      themeManager.loadBuiltInTheme(.claude)
      return
    }

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
    themeManager.loadBuiltInTheme(.claude)
  }

  private func isSentryTheme(_ metadata: ThemeManager.ThemeMetadata) -> Bool {
    isSentryThemeId(metadata.id) || metadata.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "sentry"
  }

  private func isSentryThemeId(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "sentry" || normalized == "sentry.yaml" || normalized == "sentry.yml"
  }

  private func localIPAddress() -> String {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "localhost" }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let sa = ptr.pointee.ifa_addr.pointee
      guard sa.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: ptr.pointee.ifa_name)
      guard name == "en0" || name == "en1" else { continue }
      var addr = ptr.pointee.ifa_addr.pointee
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      getnameinfo(&addr, socklen_t(sa.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
      return String(cString: hostname)
    }
    return "localhost"
  }
}
