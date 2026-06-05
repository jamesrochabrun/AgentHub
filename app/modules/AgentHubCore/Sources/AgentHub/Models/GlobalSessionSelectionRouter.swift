//
//  GlobalSessionSelectionRouter.swift
//  AgentHub
//

import Foundation

// MARK: - GlobalSessionSelectionRequest

public struct GlobalSessionSelectionRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let providerKind: SessionProviderKind
  public let sessionId: String
  public let itemId: String
  public let projectPath: String

  public init(
    id: UUID = UUID(),
    providerKind: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    itemId: String? = nil
  ) {
    self.id = id
    self.providerKind = providerKind
    self.sessionId = sessionId
    self.itemId = itemId ?? Self.itemId(providerKind: providerKind, sessionId: sessionId)
    self.projectPath = projectPath
  }

  public static func itemId(providerKind: SessionProviderKind, sessionId: String) -> String {
    "\(providerKind.rawValue.lowercased())-\(sessionId)"
  }
}

// MARK: - GlobalSessionSelectionRouter

@MainActor
@Observable
public final class GlobalSessionSelectionRouter {
  public private(set) var selectionRequest: GlobalSessionSelectionRequest?

  public init() {}

  public func select(
    providerKind: SessionProviderKind,
    sessionId: String,
    projectPath: String,
    itemId: String? = nil
  ) {
    selectionRequest = GlobalSessionSelectionRequest(
      providerKind: providerKind,
      sessionId: sessionId,
      projectPath: projectPath,
      itemId: itemId
    )
  }

  public func markConsumed(_ request: GlobalSessionSelectionRequest) {
    guard selectionRequest?.id == request.id else { return }
    selectionRequest = nil
  }
}
