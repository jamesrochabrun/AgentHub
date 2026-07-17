//
//  AgentWorkspaceCloseConfirmationModifier.swift
//  AgentHub
//

import SwiftUI

struct AgentWorkspaceCloseConfirmationModifier: ViewModifier {
  @Binding var workspaceID: String?
  let onConfirm: () -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(
      "Close Workspace?",
      isPresented: Binding(
        get: { workspaceID != nil },
        set: { if !$0 { workspaceID = nil } }
      )
    ) {
      Button("Close Workspace", role: .destructive, action: onConfirm)
      Button("Cancel", role: .cancel) {
        workspaceID = nil
      }
    } message: {
      Text("Running terminal processes will stop. Linked Claude and Codex session history will remain available.")
    }
  }
}
