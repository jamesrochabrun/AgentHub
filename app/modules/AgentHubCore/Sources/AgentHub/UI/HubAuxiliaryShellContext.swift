//
//  HubAuxiliaryShellContext.swift
//  AgentHub
//

import Foundation

struct HubAuxiliaryShellContext: Equatable {
  let providerKind: SessionProviderKind
  let terminalKey: String
  let sessionId: String?
  let projectPath: String?
  let isLaunchable: Bool
  let placeholderMessage: String?
}

extension HubAuxiliaryShellContext {
  static func monitored(session: CLISession, providerKind: SessionProviderKind) -> HubAuxiliaryShellContext {
    HubAuxiliaryShellContext(
      providerKind: providerKind,
      terminalKey: session.id,
      sessionId: session.id,
      projectPath: session.projectPath,
      isLaunchable: !session.projectPath.isEmpty,
      placeholderMessage: nil
    )
  }

  static func pending(pending: PendingHubSession, providerKind: SessionProviderKind) -> HubAuxiliaryShellContext {
    let waitsForGeneratedWorktree = providerKind == .claude && pending.worktreeName?.isEmpty == true
    return HubAuxiliaryShellContext(
      providerKind: providerKind,
      terminalKey: "pending-\(pending.id.uuidString)",
      sessionId: nil,
      projectPath: waitsForGeneratedWorktree ? nil : pending.worktree.path,
      isLaunchable: !waitsForGeneratedWorktree,
      placeholderMessage: waitsForGeneratedWorktree
        ? "Shell will be available once the worktree path is created."
        : nil
    )
  }
}
