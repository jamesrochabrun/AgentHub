//
//  MCPJSONRPCClient.swift
//  AgentHub
//

import AgentHubMCPUI
import Foundation

public protocol MCPJSONRPCClientProtocol: Sendable {
  func start() throws
  func request(
    method: String,
    params: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue
  func notify(method: String, params: AgentHubMCPUIJSONValue?) async throws
  func close()
}

public protocol MCPJSONRPCClientFactoryProtocol: Sendable {
  func makeClient(
    config: MCPServerConfiguration,
    requestTimeoutSeconds: TimeInterval
  ) throws -> any MCPJSONRPCClientProtocol
}

public struct DefaultMCPJSONRPCClientFactory: MCPJSONRPCClientFactoryProtocol {
  public init() {}

  public func makeClient(
    config: MCPServerConfiguration,
    requestTimeoutSeconds: TimeInterval
  ) throws -> any MCPJSONRPCClientProtocol {
    switch config.transport {
    case .stdio:
      return MCPStdioJSONRPCClient(config: config, requestTimeoutSeconds: requestTimeoutSeconds)
    case .streamableHTTP, .sse:
      return try MCPHTTPJSONRPCClient(config: config, requestTimeoutSeconds: requestTimeoutSeconds)
    case .unsupportedAuthentication(let reason):
      throw MCPAppDiscoveryError.unsupportedAuthentication(reason)
    case .unsupported(let transport):
      throw MCPAppDiscoveryError.unsupportedTransport(transport)
    }
  }
}

enum MCPJSONRPCMessage {
  static let protocolVersion = "2025-06-18"

  static func requestEnvelope(
    id: Int,
    method: String,
    params: AgentHubMCPUIJSONValue?
  ) -> AgentHubMCPUIJSONValue {
    .object([
      "jsonrpc": .string("2.0"),
      "id": .number(Double(id)),
      "method": .string(method),
      "params": params ?? .object([:])
    ])
  }

  static func notificationEnvelope(
    method: String,
    params: AgentHubMCPUIJSONValue?
  ) -> AgentHubMCPUIJSONValue {
    .object([
      "jsonrpc": .string("2.0"),
      "method": .string(method),
      "params": params ?? .object([:])
    ])
  }

  static var initializeParams: AgentHubMCPUIJSONValue {
    .object([
      "protocolVersion": .string(protocolVersion),
      "capabilities": .object([
        "tools": .object([:]),
        "resources": .object([:])
      ]),
      "clientInfo": .object([
        "name": .string("AgentHub"),
        "version": .string("1.0.0")
      ])
    ])
  }

  static func result(
    from response: AgentHubMCPUIJSONValue,
    expectedID id: Int,
    method: String
  ) throws -> AgentHubMCPUIJSONValue? {
    guard let object = response.objectValue else {
      throw MCPAppDiscoveryError.invalidResponse(String(describing: response.jsonObject))
    }

    guard object["id"] == .number(Double(id)) else {
      return nil
    }

    if let error = object["error"] {
      throw MCPAppDiscoveryError.remoteError(errorDescription(from: error))
    }

    guard let result = object["result"] else {
      throw MCPAppDiscoveryError.invalidResponse("Response for \(method) did not include result.")
    }
    return result
  }

  static func errorDescription(from value: AgentHubMCPUIJSONValue) -> String {
    if let object = value.objectValue {
      return object["message"]?.stringValue ?? String(describing: value.jsonObject)
    }
    return String(describing: value.jsonObject)
  }
}
