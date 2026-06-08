//
//  MCPAppResourceExtractor.swift
//  AgentHub
//

import AgentHubMCPUI
import Foundation

enum MCPAppResourceExtractor {
  static func extract(from value: Any, serverName: String? = nil) -> [MCPAppResourceDescriptor] {
    var descriptors: [MCPAppResourceDescriptor] = []
    extract(from: value, serverName: serverName, into: &descriptors)
    return deduplicated(descriptors)
  }

  static func serverName(fromToolName toolName: String?) -> String? {
    guard let toolName, toolName.hasPrefix("mcp__") else { return nil }
    let parts = toolName.split(separator: "__", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return nil }
    return parts[1]
  }

  static func metadata(from value: Any?) -> AgentHubMCPUIResourceMetadata {
    guard let value else { return AgentHubMCPUIResourceMetadata() }
    guard let object = value as? [String: Any] else { return AgentHubMCPUIResourceMetadata() }

    let ui = object["_meta"].flatMap { ($0 as? [String: Any])?["ui"] as? [String: Any] }
      ?? object["ui"] as? [String: Any]
      ?? object
    let openAIWidgetCSP = (object["_meta"] as? [String: Any])?["openai/widgetCSP"] as? [String: Any]
      ?? object["openai/widgetCSP"] as? [String: Any]

    let cspSource = ui["csp"] as? [String: Any] ?? openAIWidgetCSP
    let permissionsSource = ui["permissions"] as? [String: Any]
      ?? object["permissions"] as? [String: Any]

    let title = string(in: ui, keys: ["title", "name"])
      ?? string(in: object, keys: ["title", "name"])
    let description = string(in: ui, keys: ["description"])
      ?? string(in: object, keys: ["openai/widgetDescription", "description"])

    return AgentHubMCPUIResourceMetadata(
      title: title,
      description: description,
      permissions: permissions(from: permissionsSource),
      csp: csp(from: cspSource)
    )
  }

  static func merge(
    _ primary: AgentHubMCPUIResourceMetadata,
    _ fallback: AgentHubMCPUIResourceMetadata
  ) -> AgentHubMCPUIResourceMetadata {
    AgentHubMCPUIResourceMetadata(
      title: primary.title ?? fallback.title,
      description: primary.description ?? fallback.description,
      permissions: AgentHubMCPUIPermissions(
        allowOpenLinks: primary.permissions.allowOpenLinks && fallback.permissions.allowOpenLinks,
        allowedToolNames: primary.permissions.allowedToolNames ?? fallback.permissions.allowedToolNames,
        allowCamera: primary.permissions.allowCamera && fallback.permissions.allowCamera,
        allowMicrophone: primary.permissions.allowMicrophone && fallback.permissions.allowMicrophone,
        allowGeolocation: primary.permissions.allowGeolocation && fallback.permissions.allowGeolocation
      ),
      csp: AgentHubMCPUICSP(
        connectDomains: unique(primary.csp.connectDomains + fallback.csp.connectDomains),
        resourceDomains: unique(primary.csp.resourceDomains + fallback.csp.resourceDomains)
      )
    )
  }

  private static func extract(
    from value: Any,
    serverName inheritedServerName: String?,
    into descriptors: inout [MCPAppResourceDescriptor]
  ) {
    switch value {
    case let string as String:
      appendURIs(in: string, serverName: inheritedServerName, into: &descriptors)

    case let array as [Any]:
      for item in array {
        extract(from: item, serverName: inheritedServerName, into: &descriptors)
      }

    case let dictionary as [String: Any]:
      let serverName = inferredServerName(from: dictionary) ?? inheritedServerName
      appendDescriptor(from: dictionary, serverName: serverName, into: &descriptors)

      if let resource = dictionary["resource"] as? [String: Any] {
        appendDescriptor(from: resource, serverName: serverName, inheritedMetadata: metadata(from: dictionary), into: &descriptors)
      }

      if let meta = dictionary["_meta"] as? [String: Any] {
        appendDescriptor(fromMetadata: meta, titleSource: dictionary, serverName: serverName, into: &descriptors)
      }

      for nested in dictionary.values {
        extract(from: nested, serverName: serverName, into: &descriptors)
      }

    default:
      break
    }
  }

  private static func appendDescriptor(
    from dictionary: [String: Any],
    serverName: String?,
    inheritedMetadata: AgentHubMCPUIResourceMetadata = AgentHubMCPUIResourceMetadata(),
    into descriptors: inout [MCPAppResourceDescriptor]
  ) {
    guard let uri = string(in: dictionary, keys: ["uri", "resourceUri", "resource_uri"]),
          isMCPAppURI(uri) else {
      return
    }

    let mimeType = string(in: dictionary, keys: ["mimeType", "mime_type"]) ?? AgentHubMCPUIResource.htmlAppMimeType
    guard isMCPAppMimeType(mimeType) || uri.hasPrefix("ui://") else { return }

    let ownMetadata = metadata(from: dictionary)
    let mergedMetadata = merge(ownMetadata, inheritedMetadata)
    descriptors.append(MCPAppResourceDescriptor(
      serverName: serverName,
      uri: uri,
      mimeType: mimeType,
      title: string(in: dictionary, keys: ["title", "name"]) ?? mergedMetadata.title,
      text: dictionary["text"] as? String,
      metadata: mergedMetadata
    ))
  }

  private static func appendDescriptor(
    fromMetadata metadata: [String: Any],
    titleSource: [String: Any],
    serverName: String?,
    into descriptors: inout [MCPAppResourceDescriptor]
  ) {
    let ui = metadata["ui"] as? [String: Any]
    let uri = string(in: ui ?? [:], keys: ["resourceUri", "resource_uri", "uri"])
      ?? metadata["openai/outputTemplate"] as? String
    guard let uri, isMCPAppURI(uri) else { return }

    let resourceMetadata = Self.metadata(from: ["_meta": metadata])
    descriptors.append(MCPAppResourceDescriptor(
      serverName: serverName,
      uri: uri,
      title: string(in: titleSource, keys: ["title", "name"]) ?? resourceMetadata.title,
      metadata: resourceMetadata
    ))
  }

  private static func appendURIs(
    in text: String,
    serverName: String?,
    into descriptors: inout [MCPAppResourceDescriptor]
  ) {
    guard let regex = try? NSRegularExpression(
      pattern: "ui://[^\\s)\\]>\"'`]+",
      options: []
    ) else { return }

    let range = NSRange(text.startIndex..., in: text)
    for match in regex.matches(in: text, options: [], range: range) {
      guard let matchRange = Range(match.range, in: text) else { continue }
      var uri = String(text[matchRange])
      while let last = uri.last, [".", ",", ";", ":"].contains(String(last)) {
        uri.removeLast()
      }
      descriptors.append(MCPAppResourceDescriptor(serverName: serverName, uri: uri))
    }
  }

  private static func inferredServerName(from dictionary: [String: Any]) -> String? {
    if let explicit = string(in: dictionary, keys: ["server", "serverName", "server_name", "mcpServer", "mcp_server"]) {
      return explicit
    }
    return serverName(fromToolName: dictionary["name"] as? String)
      ?? serverName(fromToolName: dictionary["toolName"] as? String)
      ?? serverName(fromToolName: dictionary["tool_name"] as? String)
  }

  private static func permissions(from dictionary: [String: Any]?) -> AgentHubMCPUIPermissions {
    guard let dictionary else { return AgentHubMCPUIPermissions() }
    return AgentHubMCPUIPermissions(
      allowOpenLinks: bool(in: dictionary, keys: ["openLinks", "open_links", "allowOpenLinks"]) ?? true,
      allowedToolNames: stringArray(in: dictionary, keys: ["tools", "toolNames", "allowedToolNames"]),
      allowCamera: bool(in: dictionary, keys: ["camera", "allowCamera"]) ?? false,
      allowMicrophone: bool(in: dictionary, keys: ["microphone", "allowMicrophone"]) ?? false,
      allowGeolocation: bool(in: dictionary, keys: ["geolocation", "allowGeolocation"]) ?? false
    )
  }

  private static func csp(from dictionary: [String: Any]?) -> AgentHubMCPUICSP {
    guard let dictionary else { return AgentHubMCPUICSP() }
    return AgentHubMCPUICSP(
      connectDomains: stringArray(in: dictionary, keys: ["connect_domains", "connectDomains"]) ?? [],
      resourceDomains: stringArray(in: dictionary, keys: ["resource_domains", "resourceDomains"]) ?? []
    )
  }

  private static func isMCPAppURI(_ uri: String) -> Bool {
    uri.hasPrefix("ui://")
  }

  private static func isMCPAppMimeType(_ mimeType: String) -> Bool {
    mimeType.lowercased() == AgentHubMCPUIResource.htmlAppMimeType
  }

  private static func deduplicated(_ descriptors: [MCPAppResourceDescriptor]) -> [MCPAppResourceDescriptor] {
    var seen = Set<String>()
    var result: [MCPAppResourceDescriptor] = []
    for descriptor in descriptors {
      let key = "\(descriptor.serverName ?? "")|\(descriptor.uri)"
      guard seen.insert(key).inserted else { continue }
      result.append(descriptor)
    }
    return result
  }

  private static func string(in dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = dictionary[key] as? String, !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private static func bool(in dictionary: [String: Any], keys: [String]) -> Bool? {
    for key in keys {
      if let value = dictionary[key] as? Bool {
        return value
      }
    }
    return nil
  }

  private static func stringArray(in dictionary: [String: Any], keys: [String]) -> [String]? {
    for key in keys {
      if let values = dictionary[key] as? [String] {
        return values
      }
      if let values = dictionary[key] as? [Any] {
        let strings = values.compactMap { $0 as? String }
        if !strings.isEmpty {
          return strings
        }
      }
    }
    return nil
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
}
