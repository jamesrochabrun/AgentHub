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
