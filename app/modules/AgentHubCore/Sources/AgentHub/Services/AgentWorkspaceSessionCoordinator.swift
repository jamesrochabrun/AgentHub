//
//  AgentWorkspaceSessionCoordinator.swift
//  AgentHub
//

import Foundation

@MainActor
public final class AgentWorkspaceSessionCoordinator: AgentWorkspaceSessionCoordinating {
  private let claudeViewModel: CLISessionsViewModel
  private let codexViewModel: CLISessionsViewModel

  public init(
    claudeViewModel: CLISessionsViewModel,
    codexViewModel: CLISessionsViewModel
  ) {
    self.claudeViewModel = claudeViewModel
    self.codexViewModel = codexViewModel
  }

  public func cliConfiguration(for provider: SessionProviderKind) -> CLICommandConfiguration {
    viewModel(for: provider).cliConfiguration(for: provider)
  }

  public func monitorDetectedSession(_ result: AccessorySessionDetectionResult) {
    let viewModel = viewModel(for: result.provider)
    let session = CLISession(
      id: result.sessionId,
      projectPath: result.projectPath,
      branchName: result.branchName,
      lastActivityAt: .now,
      isActive: true,
      sessionFilePath: result.sessionFilePath
    )
    viewModel.startMonitoring(session: session)
    viewModel.refresh()
  }

  public func activity(for links: [AgentWorkspaceSessionLink]) -> AgentWorkspaceActivity {
    links.reduce(.idle) { activity, link in
      guard let provider = link.providerKind,
            let status = viewModel(for: provider).monitorStates[link.sessionId]?.status else {
        return activity
      }
      return max(activity, Self.activity(for: status))
    }
  }

  private func viewModel(for provider: SessionProviderKind) -> CLISessionsViewModel {
    provider == .claude ? claudeViewModel : codexViewModel
  }

  private static func activity(for status: SessionStatus) -> AgentWorkspaceActivity {
    switch status {
    case .awaitingApproval: .needsAttention
    case .thinking, .executingTool: .working
    case .waitingForUser: .ready
    case .idle: .idle
    }
  }
}
