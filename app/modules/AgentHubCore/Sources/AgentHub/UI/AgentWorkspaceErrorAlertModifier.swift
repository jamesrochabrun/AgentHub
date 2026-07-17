//
//  AgentWorkspaceErrorAlertModifier.swift
//  AgentHub
//

import SwiftUI

struct AgentWorkspaceErrorAlertModifier: ViewModifier {
  @Bindable var viewModel: AgentWorkspacesViewModel

  func body(content: Content) -> some View {
    content.alert(
      "Workspace Error",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil },
        set: { if !$0 { viewModel.clearError() } }
      )
    ) {
      Button("OK", action: viewModel.clearError)
    } message: {
      Text(viewModel.errorMessage ?? "")
    }
  }
}
