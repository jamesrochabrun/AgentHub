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

/// An MCP tool call the agent made whose tool declares an MCP app UI
/// (`_meta.ui.resourceUri`). Captured from the session JSONL: the `arguments`
/// come from the tool_use input and the `result` from the tool_result. These
/// are pushed to the rendered app via `ui/notifications/tool-input` and
/// `ui/notifications/tool-result` so it draws — neither requires the app shell
/// to be embedded in the transcript (Claude Code never embeds it).
public struct MCPAppInvocation: Identifiable, Sendable, Equatable {
  /// The tool_use id — unique per invocation.
  public let id: String
  public let serverName: String
  public let toolName: String
  /// Tool call arguments (the tool_use input), pushed as `tool-input`.
  public let arguments: AgentHubMCPUIJSONValue?
  /// Tool result content, parsed from the tool_result, pushed as `tool-result`.
  public let result: AgentHubMCPUIJSONValue?

  public init(
    id: String,
    serverName: String,
    toolName: String,
    arguments: AgentHubMCPUIJSONValue? = nil,
    result: AgentHubMCPUIJSONValue? = nil
  ) {
    self.id = id
    self.serverName = serverName
    self.toolName = toolName
    self.arguments = arguments
    self.result = result
  }
}

/// A resolved, renderable MCP app: the fetched app shell resource paired with
/// the agent invocation whose data seeds it.
public struct MCPAppRenderItem: Identifiable, Sendable, Equatable {
  public var id: String { invocation?.id ?? resource.id }
  public let resource: MCPAppResource
  public let invocation: MCPAppInvocation?

  public init(resource: MCPAppResource, invocation: MCPAppInvocation?) {
    self.resource = resource
    self.invocation = invocation
  }
}

public extension AgentHubMCPUIJSONValue {
  /// Bridges a decoded `AnyCodable`-style `Any` (Bool/Int/Double/String/Array/Dict/NSNull)
  /// into the bridge's JSON value type. Used to relay JSONL tool input/results to MCP apps.
  init(any: Any) {
    switch any {
    case is NSNull:
      self = .null
    case let bool as Bool:
      self = .bool(bool)
    case let int as Int:
      self = .number(Double(int))
    case let double as Double:
      self = .number(double)
    case let string as String:
      self = .string(string)
    case let array as [Any]:
      self = .array(array.map { AgentHubMCPUIJSONValue(any: $0) })
    case let object as [String: Any]:
      self = .object(object.mapValues { AgentHubMCPUIJSONValue(any: $0) })
    default:
      self = .null
    }
  }

  /// Bridges back to an `Any` tree (for APIs that take `[String: Any]`, e.g. metadata extraction).
  var anyValue: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let bool): return bool
    case .number(let number): return number
    case .string(let string): return string
    case .array(let array): return array.map(\.anyValue)
    case .object(let object): return object.mapValues(\.anyValue)
    }
  }
}

/// Optional invocation on a render item — present for host-rendered apps (the
/// agent's tool call data to push), nil for resources embedded directly in the JSONL.
public extension MCPAppRenderItem {
  init(resource: MCPAppResource) {
    self.init(resource: resource, invocation: nil)
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
