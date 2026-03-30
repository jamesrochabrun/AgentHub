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
    let projectPath = pendingProjectPath(for: pending, providerKind: providerKind)
    return HubAuxiliaryShellContext(
      providerKind: providerKind,
      terminalKey: "pending-\(pending.id.uuidString)",
      sessionId: nil,
      projectPath: projectPath,
      isLaunchable: projectPath != nil,
      placeholderMessage: projectPath == nil
        ? "Shell will be available once Claude creates the worktree."
        : nil
    )
  }

  private static func pendingProjectPath(
    for pending: PendingHubSession,
    providerKind: SessionProviderKind
  ) -> String? {
    guard providerKind == .claude, let worktreeName = pending.worktreeName else {
      return pending.worktree.path
    }

    guard !worktreeName.isEmpty else {
      return nil
    }

    let expectedPath = pending.worktree.path + "/.claude/worktrees/" + worktreeName
    return FileManager.default.fileExists(atPath: expectedPath) ? expectedPath : nil
  }
}
