//
//  MCPConnectorInstallService.swift
//  AgentHub
//

import Foundation

public enum MCPConnectorProviderInstallState: Equatable, Sendable {
  case installed
  case missing
  case needsUpdate
  case invalidConfig(String)

  public var isInstalled: Bool {
    if case .installed = self { return true }
    return false
  }

  var displayName: String {
    switch self {
    case .installed:
      return "Installed"
    case .missing:
      return "Not installed"
    case .needsUpdate:
      return "Needs update"
    case .invalidConfig:
      return "Invalid config"
    }
  }
}

public struct MCPConnectorInstallationStatus: Equatable, Sendable {
  public let claude: MCPConnectorProviderInstallState
  public let codex: MCPConnectorProviderInstallState

  public init(
    claude: MCPConnectorProviderInstallState,
    codex: MCPConnectorProviderInstallState
  ) {
    self.claude = claude
    self.codex = codex
  }

  public var isGloballyInstalled: Bool {
    claude.isInstalled && codex.isInstalled
  }
}

public protocol MCPConnectorInstallServiceProtocol: Sendable {
  func installationStatus(for connector: MCPConnectorDefinition) async -> MCPConnectorInstallationStatus
  func install(_ connector: MCPConnectorDefinition) async throws
  func remove(_ connector: MCPConnectorDefinition) async throws
}

public enum MCPConnectorInstallError: LocalizedError, Sendable {
  case invalidClaudeConfig(String)
  case invalidCodexConfig(String)

  public var errorDescription: String? {
    switch self {
    case .invalidClaudeConfig(let path):
      return "Could not read Claude MCP config at \(path)."
    case .invalidCodexConfig(let path):
      return "Could not read Codex MCP config at \(path)."
    }
  }
}

public actor MCPConnectorInstallService: MCPConnectorInstallServiceProtocol {
  private let claudeConfigPath: String
  private let codexConfigPath: String

  public init(
    claudeConfigPath: String = "~/.claude.json",
    codexConfigPath: String = "~/.codex/config.toml"
  ) {
    self.claudeConfigPath = NSString(string: claudeConfigPath).expandingTildeInPath
    self.codexConfigPath = NSString(string: codexConfigPath).expandingTildeInPath
  }

  public func installationStatus(for connector: MCPConnectorDefinition) async -> MCPConnectorInstallationStatus {
    MCPConnectorInstallationStatus(
      claude: claudeInstallState(for: connector),
      codex: codexInstallState(for: connector)
    )
  }

  public func install(_ connector: MCPConnectorDefinition) async throws {
    try installClaudeConnector(connector)
    try installCodexConnector(connector)
  }

  public func remove(_ connector: MCPConnectorDefinition) async throws {
    try removeClaudeConnector(connector)
    try removeCodexConnector(connector)
  }

  private func claudeInstallState(for connector: MCPConnectorDefinition) -> MCPConnectorProviderInstallState {
    guard FileManager.default.fileExists(atPath: claudeConfigPath) else { return .missing }
    do {
      let root = try readClaudeConfig()
      guard let servers = root["mcpServers"] as? [String: Any],
            let server = servers[connector.serverName] as? [String: Any] else {
        return .missing
      }
      return connectorMatches(server, connector: connector) ? .installed : .needsUpdate
    } catch {
      return .invalidConfig(claudeConfigPath)
    }
  }

  private func codexInstallState(for connector: MCPConnectorDefinition) -> MCPConnectorProviderInstallState {
    guard let content = try? String(contentsOfFile: codexConfigPath, encoding: .utf8) else {
      return .missing
    }
    guard let server = codexServerValues(named: connector.serverName, in: content) else {
      return .missing
    }
    return connectorMatches(server, connector: connector) ? .installed : .needsUpdate
  }

  private func installClaudeConnector(_ connector: MCPConnectorDefinition) throws {
    var root = try readClaudeConfigIfPresent()
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    servers[connector.serverName] = [
      "type": connector.transportType,
      "url": connector.url.absoluteString
    ]
    root["mcpServers"] = servers
    try writeClaudeConfig(root)
  }

  private func removeClaudeConnector(_ connector: MCPConnectorDefinition) throws {
    guard FileManager.default.fileExists(atPath: claudeConfigPath) else { return }
    var root = try readClaudeConfig()
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    servers.removeValue(forKey: connector.serverName)
    if servers.isEmpty {
      root.removeValue(forKey: "mcpServers")
    } else {
      root["mcpServers"] = servers
    }
    try writeClaudeConfig(root)
  }

  private func readClaudeConfigIfPresent() throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: claudeConfigPath) else { return [:] }
    return try readClaudeConfig()
  }

  private func readClaudeConfig() throws -> [String: Any] {
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: claudeConfigPath))
      let object = try JSONSerialization.jsonObject(with: data)
      guard let root = object as? [String: Any] else {
        throw MCPConnectorInstallError.invalidClaudeConfig(claudeConfigPath)
      }
      return root
    } catch let error as MCPConnectorInstallError {
      throw error
    } catch {
      throw MCPConnectorInstallError.invalidClaudeConfig(claudeConfigPath)
    }
  }

  private func writeClaudeConfig(_ root: [String: Any]) throws {
    let url = URL(fileURLWithPath: claudeConfigPath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try JSONSerialization.data(withJSONObject: root, options: options)
    try data.write(to: url, options: .atomic)
  }

  private func installCodexConnector(_ connector: MCPConnectorDefinition) throws {
    let existing = (try? String(contentsOfFile: codexConfigPath, encoding: .utf8)) ?? ""
    let withoutConnector = removingCodexServer(named: connector.serverName, from: existing)
    let trimmed = withoutConnector.trimmingCharacters(in: .whitespacesAndNewlines)
    let separator = trimmed.isEmpty ? "" : "\n\n"
    try writeCodexConfig(trimmed + separator + codexServerBlock(for: connector))
  }

  private func removeCodexConnector(_ connector: MCPConnectorDefinition) throws {
    guard FileManager.default.fileExists(atPath: codexConfigPath) else { return }
    let existing = try String(contentsOfFile: codexConfigPath, encoding: .utf8)
    try writeCodexConfig(removingCodexServer(named: connector.serverName, from: existing))
  }

  private func writeCodexConfig(_ content: String) throws {
    let url = URL(fileURLWithPath: codexConfigPath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  private func codexServerBlock(for connector: MCPConnectorDefinition) -> String {
    """
    [mcp_servers.\(connector.serverName)]
    type = \(tomlStringLiteral(connector.transportType))
    url = \(tomlStringLiteral(connector.url.absoluteString))
    """
  }

  private func removingCodexServer(named serverName: String, from content: String) -> String {
    let lines = content.components(separatedBy: .newlines)
    var kept: [String] = []
    var isSkippingServer = false

    for line in lines {
      if let tableName = tomlTableName(from: line) {
        isSkippingServer = codexServerName(fromTable: tableName) == serverName
      }
      if !isSkippingServer {
        kept.append(line)
      }
    }

    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func codexServerValues(named serverName: String, in content: String) -> [String: Any]? {
    var values: [String: Any] = [:]
    var isReadingServer = false

    for rawLine in content.components(separatedBy: .newlines) {
      if let tableName = tomlTableName(from: rawLine) {
        isReadingServer = codexServerName(fromTable: tableName) == serverName
        continue
      }
      guard isReadingServer else { continue }

      let line = stripTOMLComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
      let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if let value = parseTOMLString(rawValue) {
        values[key] = value
      }
    }

    return values.isEmpty ? nil : values
  }

  private func connectorMatches(
    _ server: [String: Any],
    connector: MCPConnectorDefinition
  ) -> Bool {
    let url = (server["url"] as? String)
      ?? (server["serverUrl"] as? String)
      ?? (server["serverURL"] as? String)
      ?? (server["server_url"] as? String)
      ?? (server["endpoint"] as? String)
      ?? (server["uri"] as? String)

    guard url == connector.url.absoluteString else { return false }

    let transport = (server["type"] as? String)
      ?? (server["transport"] as? String)
      ?? (server["transportType"] as? String)
      ?? (server["transport_type"] as? String)

    guard let transport else { return true }
    let normalized = transport.lowercased().replacingOccurrences(of: "-", with: "_")
    return normalized == connector.transportType
      || normalized == "streamable_http"
      || normalized == "streamablehttp"
  }

  private func tomlTableName(from rawLine: String) -> String? {
    let line = stripTOMLComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
    guard line.hasPrefix("["),
          line.hasSuffix("]"),
          !line.hasPrefix("[[") else {
      return nil
    }
    return String(line.dropFirst().dropLast())
  }

  private func codexServerName(fromTable tableName: String) -> String? {
    guard tableName.hasPrefix("mcp_servers.") else { return nil }
    var suffix = String(tableName.dropFirst("mcp_servers.".count))
    if suffix.hasSuffix(".env") {
      suffix.removeLast(".env".count)
    }
    let name = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    return name.isEmpty ? nil : name
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

  private func tomlStringLiteral(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let encoded = String(data: data, encoding: .utf8) else {
      return "\"\""
    }
    return encoded
  }
}

