//
//  ProjectDetailsViewModel.swift
//  AgentHub
//

import Foundation
import Observation

/// Drives the Project Details panel: loads the skills / MCP servers / rules
/// inventory for a module. Session rows are derived live from the two
/// provider `CLISessionsViewModel`s by the view.
@MainActor
@Observable
public final class ProjectDetailsViewModel {
  public private(set) var inventory: ProjectDetailsInventory = .empty
  public private(set) var isLoading = false

  public let projectPath: String

  private let service: any ProjectDetailsInventoryServiceProtocol

  public init(
    projectPath: String,
    service: any ProjectDetailsInventoryServiceProtocol = ProjectDetailsInventoryService.shared
  ) {
    self.projectPath = projectPath
    self.service = service
  }

  public func load() async {
    isLoading = true
    inventory = await service.inventory(forProjectAt: projectPath)
    isLoading = false
  }
}
