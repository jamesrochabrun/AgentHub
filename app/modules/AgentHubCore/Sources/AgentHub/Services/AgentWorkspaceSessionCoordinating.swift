//
//  AgentWorkspaceSessionCoordinating.swift
//  AgentHub
//
//  Bridges neutral workspaces to the existing provider session view models.
//

@MainActor
public protocol AgentWorkspaceSessionCoordinating: AnyObject {
  func cliConfiguration(for provider: SessionProviderKind) -> CLICommandConfiguration
  func monitorDetectedSession(_ result: AccessorySessionDetectionResult)
  func activity(for links: [AgentWorkspaceSessionLink]) -> AgentWorkspaceActivity
}
