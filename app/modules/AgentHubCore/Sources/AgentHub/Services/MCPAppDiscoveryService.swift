//
//  MCPAppDiscoveryService.swift
//  AgentHub
//

import AgentHubMCPUI
import Foundation

public protocol MCPAppDiscoveryServiceProtocol: Sendable {
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

  /// Lazily lists a single server's tools (`tools/list`) so callers can read each
  /// tool's `_meta.ui.resourceUri` (which app a tool renders into). Scoped to the
  /// one server actually used by the agent — not a proactive sweep of all servers.
  func listTools(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue

  func shutdown() async
}

public extension MCPAppDiscoveryServiceProtocol {
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
  private let transportDescription: String
  private let client: any MCPJSONRPCClientProtocol
  private var isInitialized = false
  private var isInvalidated = false
  private var operationInProgress = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var lastUsed = Date()

  init(
    configName: String,
    transportDescription: String,
    client: any MCPJSONRPCClientProtocol
  ) {
    self.configName = configName
    self.transportDescription = transportDescription
    self.client = client
  }

  func run<T: Sendable>(
    label: String,
    operation: @Sendable (any MCPJSONRPCClientProtocol) async throws -> T
  ) async throws -> T {
    await waitForTurn()
    let started = Date()
    do {
      guard !isInvalidated else {
        throw MCPAppDiscoveryError.processClosed(configName)
      }

      if !isInitialized {
        AppLogger.mcp.info(
          "[MCPPool] initialize start server=\(self.configName, privacy: .public) transport=\(self.transportDescription, privacy: .public)"
        )
        try client.start()
        _ = try await client.request(
          method: "initialize",
          params: MCPJSONRPCMessage.initializeParams
        )
        try await client.notify(method: "notifications/initialized", params: nil)
        isInitialized = true
        AppLogger.mcp.info(
          "[MCPPool] initialize done server=\(self.configName, privacy: .public)"
        )
      }

      AppLogger.mcp.debug(
        "[MCPPool] operation start server=\(self.configName, privacy: .public) label=\(label, privacy: .public)"
      )
      lastUsed = Date()
      let value = try await operation(client)
      lastUsed = Date()
      finishTurn()
      let elapsed = Date().timeIntervalSince(started)
      AppLogger.mcp.debug(
        "[MCPPool] operation done server=\(self.configName, privacy: .public) label=\(label, privacy: .public) elapsed=\(elapsed, privacy: .public)"
      )
      return value
    } catch {
      isInvalidated = true
      isInitialized = false
      client.close()
      finishTurn()
      let elapsed = Date().timeIntervalSince(started)
      AppLogger.mcp.error(
        "[MCPPool] operation failed server=\(self.configName, privacy: .public) label=\(label, privacy: .public) elapsed=\(elapsed, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      throw error
    }
  }

  func invalidate() {
    isInvalidated = true
    isInitialized = false
    client.close()
    AppLogger.mcp.debug(
      "[MCPPool] invalidated server=\(self.configName, privacy: .public)"
    )
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
    AppLogger.mcp.info(
      "[MCPDiscovery] tool call start server=\(serverName, privacy: .public) tool=\(name, privacy: .public)"
    )
    return try await withInitializedClient(config: config, label: "tools/call:\(name)") { client in
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
    AppLogger.mcp.info(
      "[MCPDiscovery] resource read start server=\(serverName, privacy: .public) uri=\(uri, privacy: .public)"
    )
    return try await withInitializedClient(config: config, label: "resources/read") { client in
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
    AppLogger.mcp.info(
      "[MCPDiscovery] resource list start server=\(serverName, privacy: .public)"
    )
    return try await withInitializedClient(config: config, label: "resources/list") { client in
      try await client.request(method: "resources/list", params: .object([:]))
    }
  }

  public func listTools(
    provider: SessionProviderKind,
    projectPath: String,
    serverName: String
  ) async throws -> AgentHubMCPUIJSONValue {
    let config = try await configuration(
      provider: provider,
      projectPath: projectPath,
      serverName: serverName
    )
    AppLogger.mcp.info(
      "[MCPDiscovery] tool list start server=\(serverName, privacy: .public)"
    )
    return try await withInitializedClient(config: config, label: "tools/list") { client in
      try await client.request(method: "tools/list", params: .object([:]))
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

  private func withInitializedClient<T: Sendable>(
    config: MCPServerConfiguration,
    label: String,
    operation: @Sendable (any MCPJSONRPCClientProtocol) async throws -> T
  ) async throws -> T {
    await cleanupIdleClients()
    let clientKey = MCPAppServerClientKey(config: config)
    let pooledClient = try pooledClient(for: clientKey, config: config)

    do {
      return try await pooledClient.run(label: label, operation: operation)
    } catch {
      clientPool.removeValue(forKey: clientKey)
      await pooledClient.invalidate()
      throw error
    }
  }

  public func shutdown() async {
    let clients = Array(clientPool.values)
    clientPool.removeAll()
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
    let pooledClient = PooledMCPJSONRPCClient(
      configName: config.name,
      transportDescription: config.transportDescription,
      client: client
    )
    clientPool[clientKey] = pooledClient
    AppLogger.mcp.debug(
      "[MCPPool] created server=\(config.name, privacy: .public) transport=\(config.transportDescription, privacy: .public)"
    )
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
