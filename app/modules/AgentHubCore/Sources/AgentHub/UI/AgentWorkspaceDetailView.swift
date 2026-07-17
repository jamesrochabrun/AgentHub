//
//  AgentWorkspaceDetailView.swift
//  AgentHub
//

import SwiftUI

struct AgentWorkspaceDetailView: View {
  let workspace: AgentWorkspaceRecord
  let viewModel: AgentWorkspacesViewModel
  let onRename: (String?) -> Void
  let onClose: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme
  @AppStorage(AgentHubDefaults.terminalFontSize) private var terminalFontSize = 12.0
  @AppStorage(AgentHubDefaults.terminalFontFamily) private var terminalFontFamily = "SF Mono"
  @State private var isRenaming = false
  @State private var renameText = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(viewModel.displayName(for: workspace))
            .font(.headline)
          Text(workspace.projectPath)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer()

        AgentWorkspaceSurfaceMenu { kind, placement in
          viewModel.launchSurface(
            workspaceID: workspace.id,
            kind: kind,
            placement: placement,
            isDark: colorScheme == .dark
          )
        }

        Menu("Workspace Actions", systemImage: "ellipsis.circle") {
          Button("Rename", systemImage: "pencil", action: beginRename)
          Button("Close Workspace", systemImage: "xmark", role: .destructive, action: onClose)
        }
        .menuStyle(.borderlessButton)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      Divider()

      AgentWorkspaceTerminalView(
        workspaceID: workspace.id,
        viewModel: viewModel,
        isDark: colorScheme == .dark,
        fontSize: terminalFontSize,
        fontFamily: terminalFontFamily,
        theme: runtimeTheme
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .alert("Rename Workspace", isPresented: $isRenaming) {
      TextField("Workspace name", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Rename", action: commitRename)
    }
  }

  private func beginRename() {
    renameText = viewModel.displayName(for: workspace)
    isRenaming = true
  }

  private func commitRename() {
    onRename(renameText)
  }
}
