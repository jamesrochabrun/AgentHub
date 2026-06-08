//
//  MCPAppResource.swift
//  AgentHub
//

import AgentHubMCPUI
import Foundation

public enum MCPAppResourceSource: String, Codable, Sendable, Equatable, Hashable {
  case inlineJSONL
  case liveDiscovery
}

public struct MCPAppResourceDescriptor: Identifiable, Codable, Sendable, Equatable, Hashable {
  public var id: String {
    [
      serverName ?? "unknown-server",
      uri,
      source.rawValue
    ].joined(separator: "|")
  }

  public let serverName: String?
  public let uri: String
  public let mimeType: String
  public let title: String?
  public let text: String?
  public let metadata: AgentHubMCPUIResourceMetadata
  public let source: MCPAppResourceSource

  public init(
    serverName: String? = nil,
    uri: String,
    mimeType: String = AgentHubMCPUIResource.htmlAppMimeType,
    title: String? = nil,
    text: String? = nil,
    metadata: AgentHubMCPUIResourceMetadata = AgentHubMCPUIResourceMetadata(),
    source: MCPAppResourceSource = .inlineJSONL
  ) {
    self.serverName = serverName
    self.uri = uri
    self.mimeType = mimeType
    self.title = title
    self.text = text
    self.metadata = metadata
    self.source = source
  }
}

public struct MCPAppResource: Identifiable, Sendable, Equatable {
  public var id: String {
    MCPAppResourceCacheKey(
      provider: provider,
      projectPath: projectPath,
      serverName: serverName,
      uri: resource.uri
    ).id
  }

  public let provider: SessionProviderKind
  public let projectPath: String
  public let serverName: String
  public let title: String?
  public let source: MCPAppResourceSource
  public let resource: AgentHubMCPUIResource

  public init(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    title: String? = nil,
    source: MCPAppResourceSource,
    resource: AgentHubMCPUIResource
  ) {
    self.provider = provider
    self.projectPath = projectPath
    self.serverName = serverName
    self.title = title
    self.source = source
    self.resource = resource
  }
}

public struct MCPAppResourceCacheKey: Sendable, Hashable {
  public let provider: SessionProviderKind
  public let projectPath: String
  public let serverName: String
  public let uri: String

  public init(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    uri: String
  ) {
    self.provider = provider
    self.projectPath = projectPath
    self.serverName = serverName
    self.uri = uri
  }

  public var serverKey: MCPAppServerCacheKey {
    MCPAppServerCacheKey(provider: provider, projectPath: projectPath, serverName: serverName)
  }

  public var id: String {
    [
      provider.rawValue,
      projectPath,
      serverName,
      uri
    ].joined(separator: "|")
  }
}

public struct MCPAppServerCacheKey: Sendable, Hashable {
  public let provider: SessionProviderKind
  public let projectPath: String
  public let serverName: String

  public init(provider: SessionProviderKind, projectPath: String, serverName: String) {
    self.provider = provider
    self.projectPath = projectPath
    self.serverName = serverName
  }
}

public enum MCPAppServerDiscoveryState: Sendable, Equatable, Hashable {
  case loading
  case available(resourceCount: Int)
  case noResources
  case unsupportedTransport(String)
  case authenticationRequired(String)
  case unreachable(String)
  case failure(String)

  public var displayTitle: String {
    switch self {
    case .loading:
      return "Loading"
    case .available(let resourceCount):
      return resourceCount == 1 ? "1 app available" : "\(resourceCount) apps available"
    case .noResources:
      return "No MCP apps"
    case .unsupportedTransport:
      return "Unsupported transport"
    case .authenticationRequired:
      return "Authentication required"
    case .unreachable:
      return "Server unreachable"
    case .failure:
      return "Discovery failed"
    }
  }

  public var displayMessage: String {
    switch self {
    case .loading:
      return "Discovering app resources from this MCP server."
    case .available(let resourceCount):
      return resourceCount == 1
        ? "This server exposed one app resource."
        : "This server exposed \(resourceCount) app resources."
    case .noResources:
      return "This server did not expose any MCP app resources."
    case .unsupportedTransport(let message),
         .authenticationRequired(let message),
         .unreachable(let message),
         .failure(let message):
      return message
    }
  }

  public var isError: Bool {
    switch self {
    case .unsupportedTransport, .authenticationRequired, .unreachable, .failure:
      return true
    case .loading, .available, .noResources:
      return false
    }
  }
}

public struct MCPAppServerDiscoveryStatus: Identifiable, Sendable, Equatable, Hashable {
  public let key: MCPAppServerCacheKey
  public let transportDescription: String
  public let state: MCPAppServerDiscoveryState

  public init(
    key: MCPAppServerCacheKey,
    transportDescription: String,
    state: MCPAppServerDiscoveryState
  ) {
    self.key = key
    self.transportDescription = transportDescription
    self.state = state
  }

  public var id: String {
    [
      key.provider.rawValue,
      key.projectPath,
      key.serverName,
      transportDescription
    ].joined(separator: "|")
  }
}

public struct MCPAppDiscoverySnapshot: Sendable, Equatable {
  public let resources: [MCPAppResource]
  public let serverStatuses: [MCPAppServerDiscoveryStatus]

  public init(
    resources: [MCPAppResource],
    serverStatuses: [MCPAppServerDiscoveryStatus]
  ) {
    self.resources = resources
    self.serverStatuses = serverStatuses
  }
}
