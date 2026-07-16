//
//  AgentWorkspaceSurfaceMenu.swift
//  AgentHub
//

import SwiftUI

struct AgentWorkspaceSurfaceMenu: View {
  let onLaunch: (WorkspaceTerminalLaunchKind, WorkspaceSurfacePlacement) -> Void

  var body: some View {
    Menu("Add Surface", systemImage: "plus") {
      placementMenu(title: "New Tab", systemImage: "rectangle.stack", placement: .tab)
      placementMenu(title: "Split Right", systemImage: "rectangle.split.2x1", placement: .splitRight)
      placementMenu(title: "Split Down", systemImage: "rectangle.split.1x2", placement: .splitDown)
    }
    .menuStyle(.borderlessButton)
    .help("Add a shell or agent surface")
  }

  private func placementMenu(
    title: String,
    systemImage: String,
    placement: WorkspaceSurfacePlacement
  ) -> some View {
    Menu(title, systemImage: systemImage) {
      Button("Shell", systemImage: "terminal") {
        onLaunch(.shell, placement)
      }
      Button("Claude", systemImage: "sparkles") {
        onLaunch(.agent(.claude), placement)
      }
      Button("Codex", systemImage: "chevron.left.forwardslash.chevron.right") {
        onLaunch(.agent(.codex), placement)
      }
    }
  }
}
