//
//  WorktreeSettingsView.swift
//  AgentHub
//

import SwiftUI

public struct WorktreeSettingsView: View {
  @AppStorage(AgentHubDefaults.worktreeBranchPrefix)
  private var worktreeBranchPrefix: String = ""

  public init() {}

  public var body: some View {
    Form {
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
    }
    .formStyle(.grouped)
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
}
