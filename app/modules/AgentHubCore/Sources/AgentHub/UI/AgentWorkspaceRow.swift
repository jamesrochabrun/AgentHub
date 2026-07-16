//
//  AgentWorkspaceRow.swift
//  AgentHub
//

import SwiftUI

struct AgentWorkspaceRow: View {
  let workspace: AgentWorkspaceRecord
  let viewModel: AgentWorkspacesViewModel
  let isSelected: Bool
  let onSelect: () -> Void
  let onRename: (String?) -> Void
  let onClose: () -> Void

  @State private var isHovered = false
  @State private var isRenaming = false
  @State private var renameText = ""

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 8) {
        Image(systemName: "rectangle.3.group")
          .foregroundStyle(isSelected ? .primary : .secondary)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(viewModel.displayName(for: workspace))
            .font(.callout.weight(.medium))
            .lineLimit(1)
          Text(metadataText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 4)

        Image(systemName: activity.systemImage)
          .foregroundStyle(activityColor)
          .help(activity.label)
          .accessibilityLabel(activity.label)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(.rect)
      .background(
        isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(isHovered ? 0.05 : 0),
        in: .rect(cornerRadius: 6)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Rename", systemImage: "pencil", action: beginRename)
      Divider()
      Button("Close Workspace", systemImage: "xmark", role: .destructive, action: onClose)
    }
    .alert("Rename Workspace", isPresented: $isRenaming) {
      TextField("Workspace name", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Rename", action: commitRename)
    }
  }

  private var activity: AgentWorkspaceActivity {
    viewModel.activity(for: workspace.id)
  }

  private var metadataText: String {
    let panes = viewModel.paneCount(for: workspace)
    let agents = viewModel.linkedAgentCount(for: workspace.id)
    let paneLabel = panes == 1 ? "1 pane" : "\(panes) panes"
    guard agents > 0 else { return paneLabel }
    let agentLabel = agents == 1 ? "1 agent" : "\(agents) agents"
    return "\(paneLabel) · \(agentLabel)"
  }

  private var activityColor: Color {
    switch activity {
    case .idle: .secondary
    case .ready: .green
    case .working: .blue
    case .needsAttention: .yellow
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
