//
//  AgentHubMCPUIResource.swift
//  AgentHubMCPUI
//

import Foundation

public struct AgentHubMCPUIResource: Codable, Sendable, Equatable {
  public static let htmlAppMimeType = "text/html;profile=mcp-app"

  public let uri: String
  public let mimeType: String
  public let text: String
  public let metadata: AgentHubMCPUIResourceMetadata

  public init(
    uri: String,
    mimeType: String = Self.htmlAppMimeType,
    text: String,
    metadata: AgentHubMCPUIResourceMetadata = AgentHubMCPUIResourceMetadata()
  ) {
    self.uri = uri
    self.mimeType = mimeType
    self.text = text
    self.metadata = metadata
  }

  public func withMetadata(_ metadata: AgentHubMCPUIResourceMetadata) -> AgentHubMCPUIResource {
    AgentHubMCPUIResource(
      uri: uri,
      mimeType: mimeType,
      text: text,
      metadata: metadata
    )
  }
}

public struct AgentHubMCPUIResourceMetadata: Codable, Sendable, Equatable, Hashable {
  public var title: String?
  public var description: String?
  public var permissions: AgentHubMCPUIPermissions
  public var csp: AgentHubMCPUICSP

  public init(
    title: String? = nil,
    description: String? = nil,
    permissions: AgentHubMCPUIPermissions = AgentHubMCPUIPermissions(),
    csp: AgentHubMCPUICSP = AgentHubMCPUICSP()
  ) {
    self.title = title
    self.description = description
    self.permissions = permissions
    self.csp = csp
  }
}

public struct AgentHubMCPUIPermissions: Codable, Sendable, Equatable, Hashable {
  public var allowOpenLinks: Bool
  public var allowedToolNames: [String]?
  public var allowCamera: Bool
  public var allowMicrophone: Bool
  public var allowGeolocation: Bool

  public init(
    allowOpenLinks: Bool = true,
    allowedToolNames: [String]? = nil,
    allowCamera: Bool = false,
    allowMicrophone: Bool = false,
    allowGeolocation: Bool = false
  ) {
    self.allowOpenLinks = allowOpenLinks
    self.allowedToolNames = allowedToolNames
    self.allowCamera = allowCamera
    self.allowMicrophone = allowMicrophone
    self.allowGeolocation = allowGeolocation
  }
}

public struct AgentHubMCPUICSP: Codable, Sendable, Equatable, Hashable {
  public var connectDomains: [String]
  public var resourceDomains: [String]

  public init(
    connectDomains: [String] = [],
    resourceDomains: [String] = []
  ) {
    self.connectDomains = connectDomains
    self.resourceDomains = resourceDomains
  }
}

public enum AgentHubMCPUIHTML {
  public static func escape(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}
