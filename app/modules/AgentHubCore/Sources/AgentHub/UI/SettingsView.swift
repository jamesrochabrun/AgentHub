//
//  SettingsView.swift
//  AgentHub
//
//  Settings panel for app configuration.
//

import SwiftUI

public struct SettingsView: View {
  public init() {}

  public var body: some View {
    Form {
      Section("CLI Status") {
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
    .formStyle(.grouped)
    .frame(width: 300, height: 150)
  }
}
