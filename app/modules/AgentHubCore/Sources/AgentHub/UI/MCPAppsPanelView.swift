//
//  MCPAppsPanelView.swift
//  AgentHub
//

import AgentHubMCPUI
import AppKit
import SwiftUI

struct MCPAppsPanelView: View {
  let session: CLISession
  let resources: [MCPAppResource]
  let viewModel: CLISessionsViewModel?
  let onDismiss: () -> Void

  @State private var selectedResourceID: String?

  private var selectedResource: MCPAppResource? {
    let selectedID = selectedResourceID ?? resources.first?.id
    return resources.first { $0.id == selectedID } ?? resources.first
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      if resources.isEmpty {
        ContentUnavailableView(
          "No MCP Apps",
          systemImage: "square.stack.3d.up",
          description: Text("No app resources are available for this session.")
        )
        .frame(width: 820, height: 520)
      } else {
        HStack(spacing: 0) {
          resourceList
            .frame(width: 220)

          Divider()

          if let selectedResource {
            MCPAppResourceHostView(
              resource: selectedResource,
              viewModel: viewModel,
              onTeardown: onDismiss
            )
            .id(selectedResource.id)
          }
        }
        .frame(width: 980, height: 640)
      }
    }
    .onAppear {
      selectedResourceID = selectedResourceID ?? resources.first?.id
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "square.stack.3d.up")
        .foregroundStyle(Color.brandPrimary)

      VStack(alignment: .leading, spacing: 2) {
        Text("MCP Apps")
          .font(.headline)
        Text(session.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button("Close", action: onDismiss)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var resourceList: some View {
    List(selection: Binding(
      get: { selectedResourceID },
      set: { selectedResourceID = $0 }
    )) {
      ForEach(resources) { resource in
        MCPAppResourceRow(resource: resource)
          .tag(Optional(resource.id))
      }
    }
    .listStyle(.sidebar)
  }
}

private struct MCPAppResourceRow: View {
  let resource: MCPAppResource

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(resource.title ?? resource.resource.metadata.title ?? resource.resource.uri)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)

      Text(resource.serverName)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Text(resource.resource.uri)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.vertical, 4)
  }
}

private struct MCPAppResourceHostView: View {
  let resource: MCPAppResource
  let viewModel: CLISessionsViewModel?
  let onTeardown: () -> Void

  @State private var requestedHeight: CGFloat = 460
  @State private var bridgeHandler: MCPAppHostBridgeHandler?

  var body: some View {
    ScrollView {
      AgentHubMCPUIResourceView(
        resource: resource.resource,
        bridgeHandler: bridgeHandler
      )
      .frame(minHeight: requestedHeight)
      .padding(16)
    }
    .onAppear(perform: installBridgeHandler)
    .onChange(of: resource.id) { _, _ in
      installBridgeHandler()
    }
  }

  private func installBridgeHandler() {
    bridgeHandler = MCPAppHostBridgeHandler(
      resource: resource,
      viewModel: viewModel,
      onSizeChange: { width, height in
        if let height {
          requestedHeight = min(max(CGFloat(height), 240), 900)
        }
      },
      onTeardown: onTeardown
    )
  }
}

@MainActor
private final class MCPAppHostBridgeHandler: AgentHubMCPUIBridgeHandler {
  private let resource: MCPAppResource
  private weak var viewModel: CLISessionsViewModel?
  private let onSizeChange: (Double?, Double?) -> Void
  private let onTeardown: () -> Void

  init(
    resource: MCPAppResource,
    viewModel: CLISessionsViewModel?,
    onSizeChange: @escaping (Double?, Double?) -> Void,
    onTeardown: @escaping () -> Void
  ) {
    self.resource = resource
    self.viewModel = viewModel
    self.onSizeChange = onSizeChange
    self.onTeardown = onTeardown
  }

  func initialize(params: AgentHubMCPUIJSONValue?) async throws -> AgentHubMCPUIJSONValue {
    .object([
      "protocolVersion": .string("2026-01-26"),
      "host": .object([
        "name": .string("AgentHub"),
        "version": .string("1.0.0")
      ]),
      "capabilities": .object([
        "tools": .object(["call": .bool(resource.source == .liveDiscovery)]),
        "resources": .object(["read": .bool(true), "list": .bool(true)]),
        "openLinks": .object(["enabled": .bool(resource.resource.metadata.permissions.allowOpenLinks)]),
        "logging": .object([:]),
        "display": .object(["sizeChanges": .bool(true)])
      ]),
      "context": .object([
        "provider": .string(resource.provider.rawValue),
        "projectPath": .string(resource.projectPath),
        "serverName": .string(resource.serverName),
        "resourceUri": .string(resource.resource.uri),
        "theme": .string(NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light")
      ])
    ])
  }

  func callTool(
    name: String,
    arguments: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    guard resource.source == .liveDiscovery else {
      throw AgentHubMCPUIBridgeError.permissionDenied("Inline MCP app resources cannot call tools without a resolved server.")
    }
    if let allowed = resource.resource.metadata.permissions.allowedToolNames,
       !allowed.contains(name) {
      throw AgentHubMCPUIBridgeError.permissionDenied("MCP app is not allowed to call tool '\(name)'.")
    }
    guard let viewModel else {
      throw AgentHubMCPUIBridgeError.invalidRequest("AgentHub session view model is unavailable.")
    }
    return try await viewModel.callMCPAppTool(resource: resource, name: name, arguments: arguments)
  }

  func readResource(uri: String) async throws -> AgentHubMCPUIJSONValue {
    if uri == resource.resource.uri {
      return .object([
        "contents": .array([resourceContentValue(resource.resource)])
      ])
    }
    guard resource.source == .liveDiscovery, let viewModel else {
      throw AgentHubMCPUIBridgeError.permissionDenied("MCP app cannot read resources without a resolved server.")
    }
    return try await viewModel.readMCPAppResource(resource: resource, uri: uri)
  }

  func listResources() async throws -> AgentHubMCPUIJSONValue {
    guard resource.source == .liveDiscovery, let viewModel else {
      return .object([
        "resources": .array([resourceListValue(resource.resource)])
      ])
    }
    return try await viewModel.listMCPAppResources(resource: resource)
  }

  func openLink(url: URL) async throws {
    guard resource.resource.metadata.permissions.allowOpenLinks else {
      throw AgentHubMCPUIBridgeError.permissionDenied("MCP app is not allowed to open external links.")
    }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw AgentHubMCPUIBridgeError.permissionDenied("MCP app may only open http or https links.")
    }
    NSWorkspace.shared.open(url)
  }

  func appDidRequestSize(width: Double?, height: Double?) {
    onSizeChange(width, height)
  }

  func appDidRequestTeardown() {
    onTeardown()
  }

  func appDidSendMessage(_ params: AgentHubMCPUIJSONValue?) {}
  func appDidUpdateModelContext(_ params: AgentHubMCPUIJSONValue?) {}
  func appDidLogMessage(_ params: AgentHubMCPUIJSONValue?) {}

  private func resourceContentValue(_ resource: AgentHubMCPUIResource) -> AgentHubMCPUIJSONValue {
    .object([
      "uri": .string(resource.uri),
      "mimeType": .string(resource.mimeType),
      "text": .string(resource.text),
      "_meta": metadataValue(resource.metadata)
    ])
  }

  private func resourceListValue(_ resource: AgentHubMCPUIResource) -> AgentHubMCPUIJSONValue {
    .object([
      "uri": .string(resource.uri),
      "mimeType": .string(resource.mimeType),
      "name": .string(resource.metadata.title ?? resource.uri),
      "_meta": metadataValue(resource.metadata)
    ])
  }

  private func metadataValue(_ metadata: AgentHubMCPUIResourceMetadata) -> AgentHubMCPUIJSONValue {
    .object([
      "ui": .object([
        "title": .string(metadata.title ?? ""),
        "description": .string(metadata.description ?? ""),
        "permissions": .object([
          "openLinks": .bool(metadata.permissions.allowOpenLinks),
          "tools": .array((metadata.permissions.allowedToolNames ?? []).map { .string($0) })
        ]),
        "csp": .object([
          "connect_domains": .array(metadata.csp.connectDomains.map { .string($0) }),
          "resource_domains": .array(metadata.csp.resourceDomains.map { .string($0) })
        ])
      ])
    ])
  }
}
