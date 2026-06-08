//
//  MCPServerConfigurationResolver.swift
//  AgentHub
//

import Foundation

enum MCPProjectPathNormalizer {
  static func normalize(_ projectPath: String) -> String {
    NSString(string: projectPath).expandingTildeInPath
  }
}

public enum MCPServerTransport: Sendable, Equatable {
  case stdio
  case streamableHTTP(URL, legacySSEFallback: Bool)
  case sse(URL)
  case unsupportedAuthentication(String)
  case unsupported(String)
}

public struct MCPServerConfiguration: Sendable, Equatable {
  public let provider: SessionProviderKind
  public let projectPath: String
  public let name: String
  public let command: String?
  public let args: [String]
  public let env: [String: String]
  public let cwd: String?
  public let transport: MCPServerTransport

  public init(
    provider: SessionProviderKind,
    projectPath: String,
    name: String,
    command: String? = nil,
    args: [String] = [],
    env: [String: String] = [:],
    cwd: String? = nil,
    transport: MCPServerTransport = .stdio
  ) {
    self.provider = provider
    self.projectPath = projectPath
    self.name = name
    self.command = command
    self.args = args
    self.env = env
    self.cwd = cwd
    self.transport = transport
  }

  public var serverKey: MCPAppServerCacheKey {
    MCPAppServerCacheKey(provider: provider, projectPath: projectPath, serverName: name)
  }

  public var transportIdentity: String {
    switch transport {
    case .stdio:
      return [
        "stdio",
        command ?? "",
        args.joined(separator: "\u{1F}"),
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1F}"),
        cwd ?? projectPath
      ].joined(separator: "\u{1E}")
    case .streamableHTTP(let endpoint, let legacySSEFallback):
      return "streamable-http|\(endpoint.absoluteString)|fallback=\(legacySSEFallback)"
    case .sse(let endpoint):
      return "sse|\(endpoint.absoluteString)"
    case .unsupportedAuthentication(let reason):
      return "unsupported-auth|\(reason)"
    case .unsupported(let transport):
      return "unsupported|\(transport)"
    }
  }

  public var transportDescription: String {
    switch transport {
    case .stdio:
      return "stdio \((command?.isEmpty == false ? command : nil) ?? name)"
    case .streamableHTTP(let endpoint, _):
      return "HTTP \(endpoint.absoluteString)"
    case .sse(let endpoint):
      return "SSE \(endpoint.absoluteString)"
    case .unsupportedAuthentication:
      return "HTTP auth"
    case .unsupported(let transport):
      return transport
    }
  }
}

public protocol MCPServerConfigurationResolverProtocol: Sendable {
  func serverConfigurations(
    provider: SessionProviderKind,
    projectPath: String
  ) async -> [MCPServerConfiguration]
}

public actor DefaultMCPServerConfigurationResolver: MCPServerConfigurationResolverProtocol {
  private let claudeConfigPath: String
  private let codexConfigPath: String

  public init(
    claudeConfigPath: String = "~/.claude.json",
    codexConfigPath: String = "~/.codex/config.toml"
  ) {
    self.claudeConfigPath = NSString(string: claudeConfigPath).expandingTildeInPath
    self.codexConfigPath = NSString(string: codexConfigPath).expandingTildeInPath
  }

  public func serverConfigurations(
    provider: SessionProviderKind,
    projectPath: String
  ) async -> [MCPServerConfiguration] {
    switch provider {
    case .claude:
      claudeServerConfigurations(projectPath: projectPath)
    case .codex:
      codexServerConfigurations(projectPath: projectPath)
    }
  }

  private func claudeServerConfigurations(projectPath: String) -> [MCPServerConfiguration] {
    guard let data = FileManager.default.contents(atPath: claudeConfigPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }

    var servers: [String: MCPServerConfiguration] = [:]
    if let topLevel = root["mcpServers"] as? [String: Any] {
      mergeClaudeServers(topLevel, provider: .claude, projectPath: projectPath, into: &servers)
    }

    if let projects = root["projects"] as? [String: Any],
       let project = projects[projectPath] as? [String: Any],
       let projectServers = project["mcpServers"] as? [String: Any] {
      mergeClaudeServers(projectServers, provider: .claude, projectPath: projectPath, into: &servers)
    }

    return servers.values.sorted { $0.name < $1.name }
  }

  private func mergeClaudeServers(
    _ rawServers: [String: Any],
    provider: SessionProviderKind,
    projectPath: String,
    into servers: inout [String: MCPServerConfiguration]
  ) {
    for (name, value) in rawServers {
      guard let dictionary = value as? [String: Any],
            let config = configuration(
              name: name,
              provider: provider,
              projectPath: projectPath,
              dictionary: dictionary
            ) else {
        continue
      }
      servers[name] = config
    }
  }

  private func codexServerConfigurations(projectPath: String) -> [MCPServerConfiguration] {
    guard let content = try? String(contentsOfFile: codexConfigPath, encoding: .utf8) else {
      return []
    }

    var serverTables: [String: [String: Any]] = [:]
    var envTables: [String: [String: String]] = [:]
    var currentServer: String?
    var isEnvTable = false

    for rawLine in content.components(separatedBy: .newlines) {
      let line = stripTOMLComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }

      if line.hasPrefix("["), line.hasSuffix("]") {
        let table = String(line.dropFirst().dropLast())
        let parsed = parseCodexMCPTable(table)
        currentServer = parsed?.name
        isEnvTable = parsed?.isEnv == true
        continue
      }

      guard let currentServer,
            let equals = line.firstIndex(of: "=") else {
        continue
      }

      let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
      let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)

      if isEnvTable {
        if let value = parseTOMLString(rawValue) {
          envTables[currentServer, default: [:]][key] = value
        }
      } else if key == "args" {
        serverTables[currentServer, default: [:]][key] = parseTOMLStringArray(rawValue)
      } else if key == "env", let env = parseTOMLInlineStringDictionary(rawValue) {
        envTables[currentServer, default: [:]].merge(env) { _, new in new }
      } else if let value = parseTOMLString(rawValue) {
        serverTables[currentServer, default: [:]][key] = value
      }
    }

    return serverTables.compactMap { name, values in
      var dictionary = values
      if let env = envTables[name] {
        dictionary["env"] = env
      }
      return configuration(name: name, provider: .codex, projectPath: projectPath, dictionary: dictionary)
    }
    .sorted { $0.name < $1.name }
  }

  private func configuration(
    name: String,
    provider: SessionProviderKind,
    projectPath: String,
    dictionary: [String: Any]
  ) -> MCPServerConfiguration? {
    let transport = transport(from: dictionary)
    let command = dictionary["command"] as? String
    if transport == .stdio, command?.isEmpty != false {
      return nil
    }
    let args = dictionary["args"] as? [String] ?? []
    let env = dictionary["env"] as? [String: String] ?? [:]
    let cwd = dictionary["cwd"] as? String ?? dictionary["workingDirectory"] as? String
    return MCPServerConfiguration(
      provider: provider,
      projectPath: MCPProjectPathNormalizer.normalize(projectPath),
      name: name,
      command: command,
      args: args,
      env: env,
      cwd: cwd,
      transport: transport
    )
  }

  private func transport(from dictionary: [String: Any]) -> MCPServerTransport {
    let endpoint = url(from: dictionary)
    if endpoint != nil, hasUnsupportedAuthentication(in: dictionary) {
      return .unsupportedAuthentication("Authenticated remote MCP servers are not supported in this release.")
    }
    let explicit = (dictionary["transport"] as? String)
      ?? (dictionary["transportType"] as? String)
      ?? (dictionary["transport_type"] as? String)
      ?? (dictionary["type"] as? String)
    if let explicit {
      let lowered = explicit.lowercased().replacingOccurrences(of: "-", with: "_")
      if lowered == "stdio" { return .stdio }
      if ["http", "streamable_http", "streamablehttp"].contains(lowered) {
        guard let endpoint else { return .unsupported(lowered) }
        return .streamableHTTP(endpoint, legacySSEFallback: true)
      }
      if lowered == "sse" {
        guard let endpoint else { return .unsupported(lowered) }
        return .sse(endpoint)
      }
      return .unsupported(lowered)
    }
    if let endpoint {
      return .streamableHTTP(endpoint, legacySSEFallback: true)
    }
    return .stdio
  }

  private func url(from dictionary: [String: Any]) -> URL? {
    let rawValue = (dictionary["url"] as? String)
      ?? (dictionary["serverUrl"] as? String)
      ?? (dictionary["serverURL"] as? String)
      ?? (dictionary["server_url"] as? String)
      ?? (dictionary["endpoint"] as? String)
      ?? (dictionary["uri"] as? String)
    guard let rawValue, let url = URL(string: rawValue) else { return nil }
    return url
  }

  private func hasUnsupportedAuthentication(in dictionary: [String: Any]) -> Bool {
    let authKeys: Set<String> = [
      "auth",
      "authorization",
      "bearerToken",
      "bearer_token",
      "headers",
      "oauth",
      "token"
    ]
    return dictionary.keys.contains { authKeys.contains($0) }
  }

  private func parseCodexMCPTable(_ table: String) -> (name: String, isEnv: Bool)? {
    guard table.hasPrefix("mcp_servers.") else { return nil }
    var suffix = String(table.dropFirst("mcp_servers.".count))
    let isEnv = suffix.hasSuffix(".env")
    if isEnv {
      suffix.removeLast(".env".count)
    }
    let name = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    guard !name.isEmpty else { return nil }
    return (name, isEnv)
  }

  private func stripTOMLComment(_ line: String) -> String {
    var result = ""
    var quote: Character?
    var previous: Character?

    for character in line {
      if character == "\"" || character == "'" {
        if quote == nil {
          quote = character
        } else if quote == character, previous != "\\" {
          quote = nil
        }
      }

      if character == "#", quote == nil {
        break
      }

      result.append(character)
      previous = character
    }
    return result
  }

  private func parseTOMLString(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else { return nil }
    if trimmed.first == "\"", trimmed.last == "\"" {
      let inner = String(trimmed.dropFirst().dropLast())
      return inner
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
    }
    if trimmed.first == "'", trimmed.last == "'" {
      return String(trimmed.dropFirst().dropLast())
    }
    return nil
  }

  private func parseTOMLStringArray(_ value: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #""([^"\\]|\\.)*"|'[^']*'"#) else {
      return []
    }
    let range = NSRange(value.startIndex..., in: value)
    return regex.matches(in: value, range: range).compactMap { match in
      guard let matchRange = Range(match.range, in: value) else { return nil }
      return parseTOMLString(String(value[matchRange]))
    }
  }

  private func parseTOMLInlineStringDictionary(_ value: String) -> [String: String]? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.first == "{", trimmed.last == "}" else { return nil }
    let inner = trimmed.dropFirst().dropLast()
    var result: [String: String] = [:]
    for pair in inner.split(separator: ",") {
      guard let equals = pair.firstIndex(of: "=") else { continue }
      let key = String(pair[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      let rawValue = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if let value = parseTOMLString(rawValue) {
        result[key] = value
      }
    }
    return result
  }
}
