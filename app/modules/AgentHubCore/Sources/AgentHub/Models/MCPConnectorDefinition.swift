//
//  MCPConnectorDefinition.swift
//  AgentHub
//

import Foundation

public struct MCPConnectorDefinition: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let serverName: String
  public let transportType: String
  public let url: URL
  public let tags: [String]

  public init(
    id: String,
    name: String,
    serverName: String,
    transportType: String,
    url: URL,
    tags: [String]
  ) {
    self.id = id
    self.name = name
    self.serverName = serverName
    self.transportType = transportType
    self.url = url
    self.tags = tags
  }
}

public enum MCPConnectorCatalog {
  public static let excalidraw = MCPConnectorDefinition(
    id: "excalidraw",
    name: "Excalidraw",
    serverName: "excalidraw",
    transportType: "http",
    url: URL(string: "https://mcp.excalidraw.com/mcp")!,
    tags: ["MCP App"]
  )

  public static let all: [MCPConnectorDefinition] = [
    excalidraw
  ]
}

