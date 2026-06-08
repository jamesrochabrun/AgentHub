//
//  MCPAppDiscoveryService.swift
//  AgentHub
//

import AgentHubMCPUI
import Foundation

public protocol MCPAppDiscoveryServiceProtocol: Sendable {
  func discoverResourceSnapshot(
    provider: SessionProviderKind,
    projectPath: String,
    forceRefresh: Bool
  ) async -> MCPAppDiscoverySnapshot

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

  func shutdown() async
}

public extension MCPAppDiscoveryServiceProtocol {
  func discoverResources(
    provider: SessionProviderKind,
    projectPath: String,
    forceRefresh: Bool
  ) async -> [MCPAppResource] {
    await discoverResourceSnapshot(
      provider: provider,
      projectPath: projectPath,
      forceRefresh: forceRefresh
    ).resources
  }

  func shutdown() async {}
}

private struct MCPAppServerClientKey: Sendable, Hashable {
  let serverKey: MCPAppServerCacheKey
  let transportIdentity: String

  init(config: MCPServerConfiguration) {
    self.serverKey = config.serverKey
    self.transportIdentity = config.transportIdentity
  }
}

private actor PooledMCPJSONRPCClient {
  private let configName: String
  private let client: any MCPJSONRPCClientProtocol
  private var isInitialized = false
  private var isInvalidated = false
  private var operationInProgress = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var lastUsed = Date()

  init(configName: String, client: any MCPJSONRPCClientProtocol) {
    self.configName = configName
    self.client = client
  }

  func run<T: Sendable>(
    operation: @Sendable (any MCPJSONRPCClientProtocol) async throws -> T
  ) async throws -> T {
    await waitForTurn()
    do {
      guard !isInvalidated else {
        throw MCPAppDiscoveryError.processClosed(configName)
      }

      if !isInitialized {
        try client.start()
        _ = try await client.request(
          method: "initialize",
          params: MCPJSONRPCMessage.initializeParams
        )
        try await client.notify(method: "notifications/initialized", params: nil)
        isInitialized = true
      }

      lastUsed = Date()
      let value = try await operation(client)
      lastUsed = Date()
      finishTurn()
      return value
    } catch {
      isInvalidated = true
      isInitialized = false
      client.close()
      finishTurn()
      throw error
    }
  }

  func invalidate() {
    isInvalidated = true
    isInitialized = false
    client.close()
  }

  func isIdleExpired(now: Date, idleTimeoutSeconds: TimeInterval) -> Bool {
    guard !operationInProgress, !isInvalidated else { return false }
    return now.timeIntervalSince(lastUsed) >= idleTimeoutSeconds
  }

  private func waitForTurn() async {
    if !operationInProgress {
      operationInProgress = true
      return
    }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func finishTurn() {
    if waiters.isEmpty {
      operationInProgress = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

public actor MCPAppDiscoveryService: MCPAppDiscoveryServiceProtocol {
  public static let shared = MCPAppDiscoveryService()

  private let resolver: any MCPServerConfigurationResolverProtocol
  private let clientFactory: any MCPJSONRPCClientFactoryProtocol
  private let requestTimeoutSeconds: TimeInterval
  private let idleTimeoutSeconds: TimeInterval
  private var resourceCache: [MCPAppServerClientKey: [MCPAppResource]] = [:]
  private var clientPool: [MCPAppServerClientKey: PooledMCPJSONRPCClient] = [:]

  public init(
    resolver: any MCPServerConfigurationResolverProtocol = DefaultMCPServerConfigurationResolver(),
    clientFactory: any MCPJSONRPCClientFactoryProtocol = DefaultMCPJSONRPCClientFactory(),
    requestTimeoutSeconds: TimeInterval = 6.0,
    idleTimeoutSeconds: TimeInterval = 120.0
  ) {
    self.resolver = resolver
    self.clientFactory = clientFactory
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.idleTimeoutSeconds = idleTimeoutSeconds
  }

  public func discoverResourceSnapshot(
    provider: SessionProviderKind,
    projectPath: String,
    forceRefresh: Bool = false
  ) async -> MCPAppDiscoverySnapshot {
    let normalizedProjectPath = Self.normalize(projectPath)
    await cleanupIdleClients()

    if forceRefresh {
      await invalidateClients(provider: provider, projectPath: normalizedProjectPath)
    }

    let configs = await resolver.serverConfigurations(provider: provider, projectPath: normalizedProjectPath)
    var discovered: [MCPAppResource] = []
    var statuses: [MCPAppServerDiscoveryStatus] = []

    for config in configs {
      let clientKey = MCPAppServerClientKey(config: config)

      if !forceRefresh, let cached = resourceCache[clientKey] {
        discovered.append(contentsOf: cached)
        statuses.append(discoveryStatus(for: config, resourceCount: cached.count))
        continue
      }

      do {
        let resources = try await discoverResources(from: config)
        resourceCache[clientKey] = resources
        discovered.append(contentsOf: resources)
        statuses.append(discoveryStatus(for: config, resourceCount: resources.count))
      } catch {
        AppLogger.session.debug("MCP app discovery failed for \(config.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        resourceCache.removeValue(forKey: clientKey)
        statuses.append(discoveryStatus(for: config, error: error))
      }
    }

    return MCPAppDiscoverySnapshot(resources: discovered, serverStatuses: statuses)
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
      let tools = try await optionalDiscoveryRequest(client: client, method: "tools/list")
      let listed = try await optionalDiscoveryRequest(client: client, method: "resources/list")

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

  nonisolated private func optionalDiscoveryRequest(
    client: any MCPJSONRPCClientProtocol,
    method: String
  ) async throws -> AgentHubMCPUIJSONValue? {
    do {
      return try await client.request(method: method, params: .object([:]))
    } catch let error as MCPAppDiscoveryError {
      guard case .remoteError(let message) = error,
            Self.isUnsupportedCapabilityMessage(message) else {
        throw error
      }
      return nil
    }
  }

  nonisolated private static func isUnsupportedCapabilityMessage(_ message: String) -> Bool {
    let lowered = message.lowercased()
    return lowered.contains("method not found")
      || lowered.contains("not found")
      || lowered.contains("unsupported method")
      || lowered.contains("unknown method")
  }

  private func withInitializedClient<T: Sendable>(
    config: MCPServerConfiguration,
    operation: @Sendable (any MCPJSONRPCClientProtocol) async throws -> T
  ) async throws -> T {
    await cleanupIdleClients()
    let clientKey = MCPAppServerClientKey(config: config)
    let pooledClient = try pooledClient(for: clientKey, config: config)

    do {
      return try await pooledClient.run(operation: operation)
    } catch {
      clientPool.removeValue(forKey: clientKey)
      resourceCache.removeValue(forKey: clientKey)
      await pooledClient.invalidate()
      throw error
    }
  }

  public func shutdown() async {
    let clients = Array(clientPool.values)
    clientPool.removeAll()
    resourceCache.removeAll()
    for client in clients {
      await client.invalidate()
    }
  }

  private func pooledClient(
    for clientKey: MCPAppServerClientKey,
    config: MCPServerConfiguration
  ) throws -> PooledMCPJSONRPCClient {
    if let client = clientPool[clientKey] {
      return client
    }

    let client = try clientFactory.makeClient(config: config, requestTimeoutSeconds: requestTimeoutSeconds)
    let pooledClient = PooledMCPJSONRPCClient(configName: config.name, client: client)
    clientPool[clientKey] = pooledClient
    return pooledClient
  }

  private func cleanupIdleClients() async {
    guard idleTimeoutSeconds > 0 else { return }
    let now = Date()
    var expiredKeys: [MCPAppServerClientKey] = []
    for (key, client) in clientPool {
      if await client.isIdleExpired(now: now, idleTimeoutSeconds: idleTimeoutSeconds) {
        expiredKeys.append(key)
      }
    }

    for key in expiredKeys {
      if let client = clientPool.removeValue(forKey: key) {
        await client.invalidate()
      }
    }
  }

  private func invalidateClients(provider: SessionProviderKind, projectPath: String) async {
    let matchingKeys = clientPool.keys.filter {
      $0.serverKey.provider == provider && $0.serverKey.projectPath == projectPath
    }
    let matchingResourceKeys = resourceCache.keys.filter {
      $0.serverKey.provider == provider && $0.serverKey.projectPath == projectPath
    }

    for key in matchingKeys {
      if let client = clientPool.removeValue(forKey: key) {
        await client.invalidate()
      }
      resourceCache.removeValue(forKey: key)
    }
    for key in matchingResourceKeys {
      resourceCache.removeValue(forKey: key)
    }
  }

  private func discoveryStatus(
    for config: MCPServerConfiguration,
    resourceCount: Int
  ) -> MCPAppServerDiscoveryStatus {
    MCPAppServerDiscoveryStatus(
      key: config.serverKey,
      transportDescription: config.transportDescription,
      state: resourceCount == 0 ? .noResources : .available(resourceCount: resourceCount)
    )
  }

  private func discoveryStatus(
    for config: MCPServerConfiguration,
    error: Error
  ) -> MCPAppServerDiscoveryStatus {
    MCPAppServerDiscoveryStatus(
      key: config.serverKey,
      transportDescription: config.transportDescription,
      state: discoveryState(from: error)
    )
  }

  private func discoveryState(from error: Error) -> MCPAppServerDiscoveryState {
    if let error = error as? MCPAppDiscoveryError {
      switch error {
      case .unsupportedTransport:
        return .unsupportedTransport(error.localizedDescription)
      case .authenticationRequired, .unsupportedAuthentication:
        return .authenticationRequired(error.localizedDescription)
      case .remoteServerUnreachable:
        return .unreachable(error.localizedDescription)
      case .serverNotFound,
           .processLaunchFailed,
           .processClosed,
           .requestTimedOut,
           .invalidResponse,
           .remoteError,
           .httpRequestFailed:
        return .failure(error.localizedDescription)
      }
    }
    return .failure(error.localizedDescription)
  }

  nonisolated private func descriptors(
    fromToolsResult result: AgentHubMCPUIJSONValue?,
    serverName: String
  ) -> [MCPAppResourceDescriptor] {
    guard let tools = result?["tools"]?.arrayValue else { return [] }
    return tools.flatMap { tool in
      MCPAppResourceExtractor.extract(from: tool.jsonObject, serverName: serverName)
    }
  }

  nonisolated private func descriptors(
    fromResourcesListResult result: AgentHubMCPUIJSONValue?,
    serverName: String
  ) -> [MCPAppResourceDescriptor] {
    guard let resources = result?["resources"]?.arrayValue else { return [] }
    return resources.flatMap { resource in
      MCPAppResourceExtractor.extract(from: resource.jsonObject, serverName: serverName)
    }
  }

  nonisolated private func readMCPUIResource(
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

  nonisolated private func deduplicatedDescriptors(_ descriptors: [MCPAppResourceDescriptor]) -> [MCPAppResourceDescriptor] {
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

  public func discoverResourceSnapshot(
    provider: SessionProviderKind,
    projectPath: String,
    forceRefresh: Bool
  ) async -> MCPAppDiscoverySnapshot {
    MCPAppDiscoverySnapshot(resources: [], serverStatuses: [])
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
  case authenticationRequired(String)
  case unsupportedAuthentication(String)
  case remoteServerUnreachable(String)
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
    case .unsupportedTransport(let transport):
      return "MCP transport '\(transport)' is not supported."
    case .authenticationRequired(let message):
      return message
    case .unsupportedAuthentication(let message):
      return message
    case .remoteServerUnreachable(let message):
      return message
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
