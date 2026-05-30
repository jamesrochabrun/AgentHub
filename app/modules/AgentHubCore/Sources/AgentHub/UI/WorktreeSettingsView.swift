//
//  WorktreeSettingsView.swift
//  AgentHub
//

import SwiftUI

public struct WorktreeSettingsView: View {
  @Environment(\.agentHub) private var agentHub
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @AppStorage(AgentHubDefaults.worktreeBranchPrefix)
  private var worktreeBranchPrefix: String = ""

  @AppStorage(AgentHubDefaults.worktreeDisplayMode)
  private var worktreeDisplayModeRawValue: String = WorktreeDisplayMode.parent.rawValue

  public init() {}

  public var body: some View {
    Form {
      Section("Display") {
        Picker("Module grouping", selection: $worktreeDisplayModeRawValue) {
          ForEach(WorktreeDisplayMode.allCases) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }

        Text(selectedDisplayMode.settingsDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Generated Branches") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Branch prefix")
            .font(.caption)
            .foregroundStyle(.secondary)

          TextField("Optional prefix, e.g. feature/", text: $worktreeBranchPrefix)
            .textFieldStyle(.roundedBorder)

          Text("AgentHub uses Claude Haiku to name launcher-created worktree branches, then prepends this prefix when set.")
            .font(.caption)
            .foregroundStyle(.secondary)

          previewBox
        }
      }

      if let agentHub {
        WorktreeInventorySection(
          claudeViewModel: agentHub.claudeSessionsViewModel,
          codexViewModel: agentHub.codexSessionsViewModel,
          inventoryService: agentHub.gitService,
          worktreeRemovalService: agentHub.gitService
        )
      } else {
        Section("Worktrees") {
          Text("AgentHub provider not found")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(settingsBackground.ignoresSafeArea())
  }

  @ViewBuilder
  private var settingsBackground: some View {
    if runtimeTheme?.hasCustomBackgrounds == true {
      Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
    } else {
      Color.clear
    }
  }

  private var previewBox: some View {
    let settings = WorktreeBranchNamingSettings(rawPrefix: worktreeBranchPrefix)

    return VStack(alignment: .leading, spacing: 4) {
      Text("Preview")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(settings.previewBranchName())
        .font(.system(.subheadline, design: .monospaced))
        .foregroundStyle(.primary)

      if !settings.normalizedPrefix.isEmpty {
        Text("Normalized prefix: \(settings.normalizedPrefix)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    )
  }

  private var selectedDisplayMode: WorktreeDisplayMode {
    WorktreeDisplayMode(rawValue: worktreeDisplayModeRawValue) ?? .parent
  }
}
