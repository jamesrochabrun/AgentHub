//
//  SettingsView.swift
//  AgentHub
//
//  Settings panel for configuring provider visibility.
//

import SwiftUI

public struct SettingsView: View {
  @AppStorage(AgentHubDefaults.enabledProviders + ".claude")
  private var claudeEnabled = true

  @AppStorage(AgentHubDefaults.enabledProviders + ".codex")
  private var codexEnabled = true

  public init() {}

  public var body: some View {
    Form {
      Section("Providers") {
        Toggle(isOn: $claudeEnabled) {
          Text("Claude")
            .foregroundColor(Color.brandPrimary(for: .claude))
        }
        Toggle(isOn: $codexEnabled) {
          Text("Codex")
            .foregroundColor(Color.brandPrimary(for: .codex))
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 300, height: 150)
  }
}
