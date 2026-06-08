//
//  MCPAppDiscoveryService.swift
//  AgentHub
//

import AgentHubMCPUI
import Foundation

public protocol MCPAppDiscoveryServiceProtocol: Sendable {
  func discoverResources(
    provider: SessionProviderKind,
    projectPath: String,
    forceRefresh: Bool
  ) async -> [MCPAppResource]

  func callTool(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    name: String,
    arguments: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue

  func readResource(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    uri: String
  ) async throws -> AgentHubMCPUIJSONValue

  func listResources(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue
}

public actor MCPAppDiscoveryService: MCPAppDiscoveryServiceProtocol {
  public static let shared = MCPAppDiscoveryService()

  private let resolver: any MCPServerConfigurationResolverProtocol
  private let clientFactory: any MCPJSONRPCClientFactoryProtocol
  private let requestTimeoutSeconds: TimeInterval
  private var resourceCache: [MCPAppServerCacheKey: [MCPAppResource]] = [:]

  public init(
    resolver: any MCPServerConfigurationResolverProtocol = DefaultMCPServerConfigurationResolver(),
    clientFactory: any MCPJSONRPCClientFactoryProtocol = DefaultMCPJSONRPCClientFactory(),
    requestTimeoutSeconds: TimeInterval = 6.0
  ) {
    self.resolver = resolver
    self.clientFactory = clientFactory
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }

  public func discoverResources(
    provider: SessionProviderKind,
    projectPath: String,
    forceRefresh: Bool = false
  ) async -> [MCPAppResource] {
    let normalizedProjectPath = Self.normalize(projectPath)
    let configs = await resolver.serverConfigurations(provider: provider, projectPath: normalizedProjectPath)
    var discovered: [MCPAppResource] = []

    for config in configs {
      let serverKey = MCPAppServerCacheKey(
        provider: provider,
        projectPath: normalizedProjectPath,
        serverName: config.name
      )

      if !forceRefresh, let cached = resourceCache[serverKey] {
        discovered.append(contentsOf: cached)
        continue
      }

      do {
        let resources = try await discoverResources(from: config)
        resourceCache[serverKey] = resources
        discovered.append(contentsOf: resources)
      } catch {
        AppLogger.session.debug("MCP app discovery failed for \(config.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        resourceCache[serverKey] = []
      }
    }

    return discovered
  }

  public func callTool(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    name: String,
    arguments: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    let config = try await configuration(
      provider: provider,
      projectPath: projectPath,
      serverName: serverName
    )
    return try await withInitializedClient(config: config) { client in
      try await client.request(
        method: "tools/call",
        params: .object([
          "name": .string(name),
          "arguments": arguments ?? .object([:])
        ])
      )
    }
  }

  public func readResource(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    uri: String
  ) async throws -> AgentHubMCPUIJSONValue {
    let config = try await configuration(
      provider: provider,
      projectPath: projectPath,
      serverName: serverName
    )
    return try await withInitializedClient(config: config) { client in
      try await client.request(method: "resources/read", params: .object(["uri": .string(uri)]))
    }
  }

  public func listResources(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue {
    let config = try await configuration(
      provider: provider,
      projectPath: projectPath,
      serverName: serverName
    )
    return try await withInitializedClient(config: config) { client in
      try await client.request(method: "resources/list", params: .object([:]))
    }
  }

  public static func normalize(_ projectPath: String) -> String {
    MCPProjectPathNormalizer.normalize(projectPath)
  }

  private func configuration(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> MCPServerConfiguration {
    let normalizedProjectPath = Self.normalize(projectPath)
    let configs = await resolver.serverConfigurations(provider: provider, projectPath: normalizedProjectPath)
    guard let config = configs.first(where: { $0.name == serverName }) else {
      throw MCPAppDiscoveryError.serverNotFound(serverName)
    }
    return config
  }

  private func discoverResources(from config: MCPServerConfiguration) async throws -> [MCPAppResource] {
    try await withInitializedClient(config: config) { client in
      let tools = try? await client.request(method: "tools/list", params: .object([:]))
      let listed = try? await client.request(method: "resources/list", params: .object([:]))

      let toolDescriptors = descriptors(fromToolsResult: tools, serverName: config.name)
      let listedDescriptors = descriptors(fromResourcesListResult: listed, serverName: config.name)
      let descriptors = deduplicatedDescriptors(toolDescriptors + listedDescriptors)

      var resources: [MCPAppResource] = []
      for descriptor in descriptors {
        guard let resource = try? await readMCPUIResource(
          uri: descriptor.uri,
          client: client,
          descriptor: descriptor
        ) else {
          continue
        }
        resources.append(MCPAppResource(
          provider: config.provider,
          projectPath: config.projectPath,
          serverName: config.name,
          title: descriptor.title ?? resource.metadata.title,
          source: .liveDiscovery,
          resource: resource
        ))
      }
      return resources
    }
  }

  private func withInitializedClient<T: Sendable>(
    config: MCPServerConfiguration,
    operation: (any MCPJSONRPCClientProtocol) async throws -> T
  ) async throws -> T {
    let client = try clientFactory.makeClient(config: config, requestTimeoutSeconds: requestTimeoutSeconds)
    do {
      try client.start()
      _ = try await client.request(
        method: "initialize",
        params: MCPJSONRPCMessage.initializeParams
      )
      try await client.notify(method: "notifications/initialized", params: nil)
      let value = try await operation(client)
      client.close()
      return value
    } catch {
      client.close()
      throw error
    }
  }

  private func descriptors(
    fromToolsResult result: AgentHubMCPUIJSONValue?,
    serverName: String
  ) -> [MCPAppResourceDescriptor] {
    guard let tools = result?["tools"]?.arrayValue else { return [] }
    return tools.flatMap { tool in
      MCPAppResourceExtractor.extract(from: tool.jsonObject, serverName: serverName)
    }
  }

  private func descriptors(
    fromResourcesListResult result: AgentHubMCPUIJSONValue?,
    serverName: String
  ) -> [MCPAppResourceDescriptor] {
    guard let resources = result?["resources"]?.arrayValue else { return [] }
    return resources.flatMap { resource in
      MCPAppResourceExtractor.extract(from: resource.jsonObject, serverName: serverName)
    }
  }

  private func readMCPUIResource(
    uri: String,
    client: any MCPJSONRPCClientProtocol,
    descriptor: MCPAppResourceDescriptor
  ) async throws -> AgentHubMCPUIResource? {
    let result = try await client.request(method: "resources/read", params: .object(["uri": .string(uri)]))
    guard let contents = result["contents"]?.arrayValue else { return nil }

    for content in contents {
      guard let object = content.objectValue else { continue }
      let contentURI = object["uri"]?.stringValue ?? uri
      guard contentURI == uri else { continue }

      let mimeType = object["mimeType"]?.stringValue
        ?? object["mime_type"]?.stringValue
        ?? descriptor.mimeType
      guard mimeType.lowercased() == AgentHubMCPUIResource.htmlAppMimeType else { continue }
      guard let text = object["text"]?.stringValue else { continue }

      let resourceMetadata = MCPAppResourceExtractor.metadata(from: object.jsonObject)
      let metadata = MCPAppResourceExtractor.merge(resourceMetadata, descriptor.metadata)
      return AgentHubMCPUIResource(
        uri: contentURI,
        mimeType: mimeType,
        text: text,
        metadata: metadata
      )
    }

    return nil
  }

  private func deduplicatedDescriptors(_ descriptors: [MCPAppResourceDescriptor]) -> [MCPAppResourceDescriptor] {
    var seen = Set<String>()
    var result: [MCPAppResourceDescriptor] = []
    for descriptor in descriptors {
      guard seen.insert(descriptor.uri).inserted else { continue }
      result.append(descriptor)
    }
    return result
  }
}

public actor NoOpMCPAppDiscoveryService: MCPAppDiscoveryServiceProtocol {
  public init() {}

  public func discoverResources(
    provider: SessionProviderKind,
    projectPath: String,
    forceRefresh: Bool
  ) async -> [MCPAppResource] {
    []
  }

  public func callTool(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    name: String,
    arguments: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    throw MCPAppDiscoveryError.serverNotFound(serverName)
  }

  public func readResource(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String,
    uri: String
  ) async throws -> AgentHubMCPUIJSONValue {
    throw MCPAppDiscoveryError.serverNotFound(serverName)
  }

  public func listResources(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue {
    throw MCPAppDiscoveryError.serverNotFound(serverName)
  }
}

public enum MCPAppDiscoveryError: LocalizedError, Sendable {
  case serverNotFound(String)
  case unsupportedTransport(String)
  case processLaunchFailed(String)
  case processClosed(String)
  case requestTimedOut(String)
  case invalidResponse(String)
  case remoteError(String)
  case httpRequestFailed(Int, String)

  public var errorDescription: String? {
    switch self {
    case .serverNotFound(let server):
      return "MCP server '\(server)' was not found."
    case .unsupportedTransport(let server):
      return "MCP server '\(server)' does not use stdio transport."
    case .processLaunchFailed(let message):
      return "Failed to launch MCP server: \(message)"
    case .processClosed(let server):
      return "MCP server '\(server)' closed the stdio connection."
    case .requestTimedOut(let method):
      return "MCP request '\(method)' timed out."
    case .invalidResponse(let message):
      return "Invalid MCP server response: \(message)"
    case .remoteError(let message):
      return message
    case .httpRequestFailed(let statusCode, let message):
      return "MCP HTTP request failed with status \(statusCode): \(message)"
    }
  }
}

private extension [String: AgentHubMCPUIJSONValue] {
  var jsonObject: [String: Any] {
    mapValues(\.jsonObject)
  }
}
