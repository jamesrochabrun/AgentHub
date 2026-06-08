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

  public init(
    uri: String,
    mimeType: String = Self.htmlAppMimeType,
    text: String
  ) {
    self.uri = uri
    self.mimeType = mimeType
    self.text = text
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
