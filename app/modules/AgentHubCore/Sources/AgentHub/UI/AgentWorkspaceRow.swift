//
//  AgentWorkspaceRow.swift
//  AgentHub
//

import SwiftUI

struct AgentWorkspaceRow: View {
  let workspace: AgentWorkspaceRecord
  let viewModel: AgentWorkspacesViewModel
  let isSelected: Bool
  var isSessionsExpanded = false
  var onToggleSessions: (() -> Void)?
  let onSelect: () -> Void
  let onRename: (String?) -> Void
  let onClose: () -> Void

  @State private var isHovered = false
  @State private var isRenaming = false
  @State private var renameText = ""

  var body: some View {
    HStack(spacing: 0) {
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

        actionsView
          .fixedSize(horizontal: true, vertical: false)
          .opacity(isHovered ? 1 : 0)
          .animation(.easeInOut(duration: 0.25), value: isHovered)

        Image(systemName: activity.systemImage)
          .foregroundStyle(activityColor)
          .help(activity.label)
          .accessibilityLabel(activity.label)
      }
      .padding(.leading, 8)
      .padding(.trailing, onToggleSessions == nil ? 8 : 4)
      .padding(.vertical, 6)
      .contentShape(.rect)
      .onTapGesture(perform: onSelect)

      if let onToggleSessions {
        Button(action: onToggleSessions) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isSessionsExpanded ? 90 : 0))
            .frame(width: 16, height: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 6)
        .help(isSessionsExpanded ? "Hide agent sessions" : "Show agent sessions")
        .accessibilityLabel(isSessionsExpanded ? "Hide agent sessions" : "Show agent sessions")
      }
    }
    .background(
      isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(isHovered ? 0.05 : 0),
      in: .rect(cornerRadius: 6)
    )
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

  private var actionsView: some View {
    Menu {
      Button("Rename", systemImage: "pencil", action: beginRename)
      Divider()
      Button("Close Workspace", systemImage: "xmark", role: .destructive, action: onClose)
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .frame(width: 20, height: 20)
        .contentShape(.rect)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Workspace actions")
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
