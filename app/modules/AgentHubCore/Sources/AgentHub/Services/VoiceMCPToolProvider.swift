//
//  VoiceMCPToolProvider.swift
//  AgentHub
//
//  Bridges the user's personal MCP servers (Claude ~/.claude.json and Codex
//  ~/.codex/config.toml) into voice conversations: enabled servers' tools are
//  wrapped as VoiceTools whose handlers proxy tools/call through the MCP
//  gateway. Servers spawn only when the user has enabled them in Voice
//  settings; configs may carry secrets in env blocks and must never be logged.
//

import AgentHubMCPUI
import AgentHubVoice
import Foundation

public struct VoiceMCPServerDescriptor: Identifiable, Sendable, Equatable {
  public let name: String
  public let providers: [SessionProviderKind]
  public let transportDescription: String
  public let unsupportedReason: String?

  public var id: String { name }
  public var isSupported: Bool { unsupportedReason == nil }

  public init(
    name: String,
    providers: [SessionProviderKind],
    transportDescription: String,
    unsupportedReason: String? = nil
  ) {
    self.name = name
    self.providers = providers
    self.transportDescription = transportDescription
    self.unsupportedReason = unsupportedReason
  }
}

@MainActor
public protocol VoiceMCPToolProviding: AnyObject {
  /// Latest built tools for the enabled servers. Also schedules a background
  /// refresh so config or tool-list changes are picked up by the next
  /// conversation start.
  func currentTools() -> [VoiceTool]

  func refresh() async

  /// Coalesced fire-and-forget refresh.
  func scheduleRefresh()

  /// All servers found in the user's Claude and Codex configs, merged by name.
  /// Reads config files only — never spawns or contacts a server.
  func discoverServers() async -> [VoiceMCPServerDescriptor]
}

@MainActor
public final class VoiceMCPToolProvider: VoiceMCPToolProviding {
  private let resolver: any MCPServerConfigurationResolverProtocol
  private let discovery: any MCPAppDiscoveryServiceProtocol
  private let enabledServerNames: @MainActor () -> Set<String>
  private let scopePath: String
  private let toolCallTimeoutSeconds: TimeInterval
  private let maxOutputCharacters: Int
  private var cachedTools: [VoiceTool] = []
  private var refreshTask: Task<Void, Never>?

  public init(
    resolver: any MCPServerConfigurationResolverProtocol = DefaultMCPServerConfigurationResolver(),
    discovery: any MCPAppDiscoveryServiceProtocol,
    enabledServerNames: @escaping @MainActor () -> Set<String> = {
      Set(
        UserDefaults.standard.stringArray(
          forKey: AgentHubDefaults.voiceMCPEnabledServers
        ) ?? []
      )
    },
    scopePath: String = NSHomeDirectory(),
    toolCallTimeoutSeconds: TimeInterval = 60,
    maxOutputCharacters: Int = 6_000
  ) {
    self.resolver = resolver
    self.discovery = discovery
    self.enabledServerNames = enabledServerNames
    self.scopePath = scopePath
    self.toolCallTimeoutSeconds = toolCallTimeoutSeconds
    self.maxOutputCharacters = maxOutputCharacters
  }

  public func currentTools() -> [VoiceTool] {
    scheduleRefresh()
    return cachedTools
  }

  public func scheduleRefresh() {
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      await self?.refresh()
      self?.refreshTask = nil
    }
  }

  public func refresh() async {
    let enabled = enabledServerNames()
    guard !enabled.isEmpty else {
      cachedTools = []
      return
    }
    var tools: [VoiceTool] = []
    for config in await mergedConfigurations() {
      guard enabled.contains(config.name), isSupported(config.transport) else { continue }
      do {
        let result = try await discovery.listTools(
          provider: config.provider,
          projectPath: config.projectPath,
          serverName: config.name
        )
        tools.append(contentsOf: makeTools(config: config, listToolsResult: result))
      } catch {
        AppLogger.mcp.error(
          "[VoiceMCP] tools/list failed server=\(config.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
      }
    }
    cachedTools = tools
  }

  public func discoverServers() async -> [VoiceMCPServerDescriptor] {
    var order: [String] = []
    var names: [String: (config: MCPServerConfiguration, providers: [SessionProviderKind])] = [:]
    for provider in [SessionProviderKind.claude, .codex] {
      for config in await resolver.serverConfigurations(provider: provider, projectPath: scopePath) {
        if var existing = names[config.name] {
          if !existing.providers.contains(provider) {
            existing.providers.append(provider)
            names[config.name] = existing
          }
        } else {
          names[config.name] = (config, [provider])
          order.append(config.name)
        }
      }
    }
    return order.compactMap { name in
      guard let entry = names[name] else { return nil }
      return VoiceMCPServerDescriptor(
        name: name,
        providers: entry.providers,
        transportDescription: entry.config.transportDescription,
        unsupportedReason: unsupportedReason(entry.config.transport)
      )
    }
  }

  /// Claude and Codex configs merged by server name; when both define the same
  /// server, the Claude entry wins so calls route through one client.
  private func mergedConfigurations() async -> [MCPServerConfiguration] {
    var order: [String] = []
    var byName: [String: MCPServerConfiguration] = [:]
    for provider in [SessionProviderKind.claude, .codex] {
      let configs = await resolver.serverConfigurations(provider: provider, projectPath: scopePath)
      for config in configs where byName[config.name] == nil {
        byName[config.name] = config
        order.append(config.name)
      }
    }
    return order.compactMap { byName[$0] }
  }

  private func isSupported(_ transport: MCPServerTransport) -> Bool {
    unsupportedReason(transport) == nil
  }

  private func unsupportedReason(_ transport: MCPServerTransport) -> String? {
    switch transport {
    case .stdio, .streamableHTTP, .sse:
      nil
    case .unsupportedAuthentication(let reason):
      reason
    case .unsupported(let transport):
      "Transport '\(transport)' is not supported."
    }
  }

  private func makeTools(
    config: MCPServerConfiguration,
    listToolsResult: AgentHubMCPUIJSONValue
  ) -> [VoiceTool] {
    guard let object = listToolsResult.jsonObject as? [String: Any],
          let rawTools = object["tools"] as? [[String: Any]] else {
      return []
    }
    return rawTools.compactMap { raw in
      guard let toolName = raw["name"] as? String, !toolName.isEmpty else { return nil }
      let description = (raw["description"] as? String)
        .flatMap { $0.isEmpty ? nil : $0 }
        ?? "Tool \(toolName) from the \(config.name) MCP server."
      return makeTool(
        config: config,
        toolName: toolName,
        description: "[\(config.name)] \(Self.clipped(description, limit: 500))",
        schema: Self.functionSchema(from: raw["inputSchema"])
      )
    }
  }

  private func makeTool(
    config: MCPServerConfiguration,
    toolName: String,
    description: String,
    schema: [String: VoiceJSONValue]
  ) -> VoiceTool {
    let discovery = discovery
    let timeout = toolCallTimeoutSeconds
    let maxOutput = maxOutputCharacters
    let provider = config.provider
    let projectPath = config.projectPath
    let serverName = config.name
    return VoiceTool(
      name: Self.namespacedToolName(server: serverName, tool: toolName),
      description: description,
      parameters: schema
    ) { data in
      let arguments = try? JSONDecoder().decode(AgentHubMCPUIJSONValue.self, from: data)
      do {
        let result = try await Self.withDeadline(seconds: timeout) {
          try await discovery.callTool(
            provider: provider,
            projectPath: projectPath,
            serverName: serverName,
            name: toolName,
            arguments: arguments
          )
        }
        return Self.encodeToolResult(result, maxOutputCharacters: maxOutput)
      } catch {
        return Self.errorJSON(
          "The \(serverName) tool call failed: \(error.localizedDescription)"
        )
      }
    }
  }

  // MARK: - Formatting

  static func namespacedToolName(server: String, tool: String) -> String {
    let maxLength = 64
    let separator = "__"
    let sanitizedTool = sanitized(tool)
    let sanitizedServer = sanitized(server)
    let serverBudget = maxLength - sanitizedTool.count - separator.count
    guard serverBudget >= 1 else {
      return String(sanitizedTool.prefix(maxLength))
    }
    return "\(sanitizedServer.prefix(serverBudget))\(separator)\(sanitizedTool)"
  }

  private static func sanitized(_ name: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )
    return String(
      String.UnicodeScalarView(
        name.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }
      )
    )
  }

  static func functionSchema(from rawSchema: Any?) -> [String: VoiceJSONValue] {
    guard let rawSchema = rawSchema as? [String: Any],
          JSONSerialization.isValidJSONObject(rawSchema),
          let data = try? JSONSerialization.data(withJSONObject: rawSchema),
          var schema = try? JSONDecoder().decode([String: VoiceJSONValue].self, from: data) else {
      return [
        "type": "object",
        "properties": .object([:]),
        "additionalProperties": .bool(false),
      ]
    }
    if schema["type"] == nil {
      schema["type"] = "object"
    }
    return schema
  }

  static func encodeToolResult(
    _ result: AgentHubMCPUIJSONValue,
    maxOutputCharacters: Int
  ) -> String {
    let object = result.jsonObject as? [String: Any]
    let content = object?["content"] as? [[String: Any]] ?? []
    var texts: [String] = []
    var nonTextItems = 0
    for item in content {
      if let text = item["text"] as? String {
        texts.append(text)
      } else {
        nonTextItems += 1
      }
    }
    var output = texts.joined(separator: "\n")
    if output.isEmpty, content.isEmpty, let object,
       let data = try? JSONSerialization.data(withJSONObject: object) {
      // Servers may return structured results without a content array.
      output = String(decoding: data, as: UTF8.self)
    }
    let truncated = output.count > maxOutputCharacters
    if truncated {
      output = String(output.prefix(maxOutputCharacters))
    }
    var payload: [String: Any] = [
      "status": (object?["isError"] as? Bool) == true ? "tool_error" : "ok",
      "output": output,
    ]
    if truncated {
      payload["truncated"] = true
    }
    if nonTextItems > 0 {
      payload["non_text_items_omitted"] = nonTextItems
    }
    return json(payload)
  }

  private static func errorJSON(_ message: String) -> String {
    json(["status": "error", "message": message])
  }

  private static func json(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    ) else {
      return #"{"status":"error"}"#
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func clipped(_ text: String, limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) : text
  }

  private static func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        throw VoiceMCPToolProviderError.timedOut(seconds)
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw VoiceMCPToolProviderError.timedOut(seconds)
      }
      return first
    }
  }
}

enum VoiceMCPToolProviderError: LocalizedError {
  case timedOut(TimeInterval)

  var errorDescription: String? {
    switch self {
    case .timedOut(let seconds):
      "The MCP tool call timed out after \(Int(seconds)) seconds."
    }
  }
}
