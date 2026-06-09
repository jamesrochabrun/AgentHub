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
  let discoveryStatuses: [MCPAppServerDiscoveryStatus]
  let isDiscovering: Bool
  let viewModel: CLISessionsViewModel?
  let onRefresh: () -> Void
  let onDismiss: () -> Void

  @State private var selectedResourceID: String?
  @State private var consentController = MCPAppConsentController()
  @State private var operationNotice: MCPAppPanelNotice?

  private var selectedResource: MCPAppResource? {
    let selectedID = selectedResourceID ?? resources.first?.id
    return resources.first { $0.id == selectedID } ?? resources.first
  }

  private var errorStatuses: [MCPAppServerDiscoveryStatus] {
    discoveryStatuses.filter(\.state.isError)
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      content
    }
    .frame(
      minWidth: 980,
      idealWidth: 1120,
      maxWidth: .infinity,
      minHeight: 640,
      idealHeight: 760,
      maxHeight: .infinity
    )
    .onAppear {
      selectedResourceID = selectedResourceID ?? resources.first?.id
    }
    .onChange(of: resources.map(\.id)) { _, ids in
      guard let selectedResourceID, ids.contains(selectedResourceID) else {
        self.selectedResourceID = ids.first
        return
      }
    }
    .confirmationDialog(
      "Allow MCP App Action?",
      isPresented: Binding(
        get: { consentController.pendingRequest != nil },
        set: { isPresented in
          if !isPresented {
            consentController.denyPendingRequest()
          }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Allow for This Panel") {
        consentController.approvePendingRequest()
      }
      .keyboardShortcut(.return, modifiers: [])

      Button("Deny", role: .cancel) {
        consentController.denyPendingRequest()
      }
      .keyboardShortcut(.escape, modifiers: [])
    } message: {
      Text(consentController.pendingRequest?.message ?? "")
    }
  }

  @ViewBuilder
  private var content: some View {
    if resources.isEmpty {
      MCPAppDiscoveryStateView(
        statuses: discoveryStatuses,
        isDiscovering: isDiscovering,
        onRefresh: onRefresh
      )
    } else {
      HStack(spacing: 0) {
        resourceList
          .frame(width: 260)

        Divider()

        VStack(spacing: 0) {
          if let operationNotice {
            MCPAppNoticeBanner(notice: operationNotice) {
              self.operationNotice = nil
            }
          } else if !errorStatuses.isEmpty {
            MCPAppDiscoveryStatusStrip(statuses: errorStatuses)
          }

          if let selectedResource {
            MCPAppResourceHostView(
              resource: selectedResource,
              viewModel: viewModel,
              consentController: consentController,
              onOperationNotice: { operationNotice = $0 },
              onTeardown: onDismiss
            )
            .id(selectedResource.id)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "square.stack.3d.up")
        .foregroundStyle(Color.brandPrimary)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("MCP Apps")
          .font(.headline)
        Text(session.displayName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

      Spacer()

      Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh MCP app discovery")
        .accessibilityLabel("Refresh MCP apps")

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
    .accessibilityLabel("MCP app resources")
  }
}

private struct MCPAppDiscoveryStateView: View {
  let statuses: [MCPAppServerDiscoveryStatus]
  let isDiscovering: Bool
  let onRefresh: () -> Void

  private var title: String {
    if isDiscovering { return "Loading MCP Apps" }
    if statuses.isEmpty { return "No MCP Apps" }
    if statuses.contains(where: { $0.state.isError }) { return "MCP Discovery Needs Attention" }
    return "No MCP Apps"
  }

  private var systemImage: String {
    if isDiscovering { return "arrow.triangle.2.circlepath" }
    if statuses.contains(where: { $0.state.isError }) { return "exclamationmark.triangle" }
    return "square.stack.3d.up"
  }

  var body: some View {
    VStack(spacing: 18) {
      if isDiscovering {
        ProgressView()
          .controlSize(.regular)
      }

      ContentUnavailableView(
        title,
        systemImage: systemImage,
        description: Text(description)
      )

      if !statuses.isEmpty {
        VStack(spacing: 8) {
          ForEach(statuses) { status in
            MCPAppServerStatusRow(status: status)
          }
        }
        .frame(maxWidth: 600)
      }

      Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel("Refresh MCP apps")
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var description: String {
    if isDiscovering {
      return "Discovering app resources from configured MCP servers."
    }
    if statuses.isEmpty {
      return "No configured MCP server exposed an app resource for this session."
    }
    if statuses.contains(where: { $0.state.isError }) {
      return "One or more MCP servers could not be used for app discovery."
    }
    return "Configured MCP servers did not expose app resources."
  }
}

private struct MCPAppDiscoveryStatusStrip: View {
  let statuses: [MCPAppServerDiscoveryStatus]

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text("Some MCP servers could not be discovered.")
          .font(.caption.weight(.semibold))
        Text(summary)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .layoutPriority(1)
      .frame(maxWidth: .infinity, alignment: .leading)

      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.10))
  }

  private var summary: String {
    let visibleStatuses = Array(statuses.prefix(4))
    let visible = visibleStatuses
      .map { "\($0.key.serverName): \($0.state.displayTitle)" }
      .joined(separator: "  •  ")
    let hiddenCount = statuses.count - visibleStatuses.count
    guard hiddenCount > 0 else { return visible }
    return "\(visible)  •  +\(hiddenCount) more"
  }
}

private struct MCPAppNoticeBanner: View {
  let notice: MCPAppPanelNotice
  let onDismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: notice.systemImage)
        .foregroundStyle(notice.tint)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(notice.title)
          .font(.caption.weight(.semibold))
        Text(notice.message)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      Spacer()

      Button("Dismiss", systemImage: "xmark", action: onDismiss)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss MCP app notice")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(notice.tint.opacity(0.10))
  }
}

private struct MCPAppServerStatusRow: View {
  let status: MCPAppServerDiscoveryStatus

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(tint)
        .frame(width: 18)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(status.key.serverName)
            .font(.system(size: 12, weight: .semibold))
          Text(status.transportDescription)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Text(status.state.displayTitle)
          .font(.caption.weight(.medium))
        Text(status.state.displayMessage)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.secondary.opacity(0.08))
    )
    .accessibilityElement(children: .combine)
  }

  private var iconName: String {
    switch status.state {
    case .loading:
      return "arrow.triangle.2.circlepath"
    case .available:
      return "checkmark.circle.fill"
    case .noResources:
      return "minus.circle"
    case .unsupportedTransport, .authenticationRequired, .unreachable, .failure:
      return "exclamationmark.triangle.fill"
    }
  }

  private var tint: Color {
    switch status.state {
    case .available:
      return .green
    case .unsupportedTransport, .authenticationRequired, .unreachable, .failure:
      return .orange
    case .loading, .noResources:
      return .secondary
    }
  }
}

private struct MCPAppResourceRow: View {
  let resource: MCPAppResource

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(resource.title ?? resource.resource.metadata.title ?? resource.resource.uri)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)

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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(resource.title ?? resource.resource.metadata.title ?? resource.resource.uri)
  }
}

private struct MCPAppResourceHostView: View {
  let resource: MCPAppResource
  let viewModel: CLISessionsViewModel?
  let consentController: MCPAppConsentController
  let onOperationNotice: (MCPAppPanelNotice) -> Void
  let onTeardown: () -> Void

  @State private var bridgeHandler: MCPAppHostBridgeHandler?

  var body: some View {
    VStack(spacing: 0) {
      resourceToolbar

      Divider()

      AgentHubMCPUIWebView(
        resource: resource.resource,
        bridgeHandler: bridgeHandler
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear(perform: installBridgeHandler)
    .onChange(of: resource.id) { _, _ in
      installBridgeHandler()
    }
  }

  private var resourceToolbar: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(resource.title ?? resource.resource.metadata.title ?? resource.resource.uri)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)

        Text(resource.resource.uri)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .layoutPriority(1)

      Spacer(minLength: 12)

      Text(resource.resource.mimeType)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
          Capsule()
            .fill(Color.secondary.opacity(0.12))
        )
        .accessibilityLabel("MIME type \(resource.resource.mimeType)")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func installBridgeHandler() {
    bridgeHandler = MCPAppHostBridgeHandler(
      resource: resource,
      viewModel: viewModel,
      consentController: consentController,
      onSizeChange: { _, _ in },
      onOperationNotice: onOperationNotice,
      onTeardown: onTeardown
    )
  }
}

@MainActor
@Observable
final class MCPAppConsentController {
  var pendingRequest: MCPAppConsentRequest?

  private var grants: Set<MCPAppConsentGrant> = []
  private var pendingContinuation: CheckedContinuation<Bool, Never>?

  func require(_ action: MCPAppConsentAction, resource: MCPAppResource) async throws {
    let grant = MCPAppConsentGrant(resourceID: resource.id, scope: action.grantScope)
    guard !grants.contains(grant) else { return }
    guard pendingRequest == nil, pendingContinuation == nil else {
      throw AgentHubMCPUIBridgeError.permissionDenied("Another MCP app permission request is pending.")
    }

    let request = MCPAppConsentRequest(resource: resource, action: action)
    let allowed = await withCheckedContinuation { continuation in
      pendingRequest = request
      pendingContinuation = continuation
    }

    if allowed {
      grants.insert(grant)
      return
    }

    throw AgentHubMCPUIBridgeError.permissionDenied(action.denialMessage)
  }

  func approvePendingRequest() {
    pendingContinuation?.resume(returning: true)
    pendingContinuation = nil
    pendingRequest = nil
  }

  func denyPendingRequest() {
    pendingContinuation?.resume(returning: false)
    pendingContinuation = nil
    pendingRequest = nil
  }
}

struct MCPAppConsentRequest: Identifiable, Equatable {
  let id = UUID()
  let resourceTitle: String
  let serverName: String
  let action: MCPAppConsentAction

  init(resource: MCPAppResource, action: MCPAppConsentAction) {
    self.resourceTitle = resource.title ?? resource.resource.metadata.title ?? resource.resource.uri
    self.serverName = resource.serverName
    self.action = action
  }

  var message: String {
    "\(resourceTitle) from \(serverName) wants to \(action.promptDescription)."
  }
}

enum MCPAppConsentAction: Equatable, Hashable {
  case callTool(String)
  case readResource(String)
  case listResources
  case openLink(URL)

  var grantScope: String {
    switch self {
    case .callTool(let name):
      return "tool:\(name)"
    case .readResource(let uri):
      return "resource:\(uri)"
    case .listResources:
      return "resources:list"
    case .openLink(let url):
      return "link:\(url.absoluteString)"
    }
  }

  var promptDescription: String {
    switch self {
    case .callTool(let name):
      return "call the tool '\(name)'"
    case .readResource(let uri):
      return "read the resource \(uri)"
    case .listResources:
      return "list resources from its MCP server"
    case .openLink(let url):
      return "open \(url.absoluteString)"
    }
  }

  var denialMessage: String {
    switch self {
    case .callTool(let name):
      return "MCP app tool call '\(name)' was denied."
    case .readResource(let uri):
      return "MCP app resource read '\(uri)' was denied."
    case .listResources:
      return "MCP app resource listing was denied."
    case .openLink(let url):
      return "MCP app external link '\(url.absoluteString)' was denied."
    }
  }
}

private struct MCPAppConsentGrant: Hashable {
  let resourceID: String
  let scope: String
}

struct MCPAppPanelNotice: Identifiable, Equatable {
  enum Kind: Equatable {
    case error
    case denied
  }

  let id = UUID()
  let kind: Kind
  let title: String
  let message: String

  var systemImage: String {
    switch kind {
    case .error:
      return "exclamationmark.triangle.fill"
    case .denied:
      return "hand.raised.fill"
    }
  }

  var tint: Color {
    switch kind {
    case .error:
      return .orange
    case .denied:
      return .red
    }
  }
}

@MainActor
final class MCPAppHostBridgeHandler: AgentHubMCPUIBridgeHandler {
  private let resource: MCPAppResource
  private weak var viewModel: CLISessionsViewModel?
  private let consentController: MCPAppConsentController
  private let onSizeChange: (Double?, Double?) -> Void
  private let onOperationNotice: (MCPAppPanelNotice) -> Void
  private let onTeardown: () -> Void

  init(
    resource: MCPAppResource,
    viewModel: CLISessionsViewModel?,
    consentController: MCPAppConsentController,
    onSizeChange: @escaping (Double?, Double?) -> Void,
    onOperationNotice: @escaping (MCPAppPanelNotice) -> Void,
    onTeardown: @escaping () -> Void
  ) {
    self.resource = resource
    self.viewModel = viewModel
    self.consentController = consentController
    self.onSizeChange = onSizeChange
    self.onOperationNotice = onOperationNotice
    self.onTeardown = onTeardown
  }

  func initialize(params: AgentHubMCPUIJSONValue?) async throws -> AgentHubMCPUIJSONValue {
    let protocolVersion = params?["protocolVersion"]?.stringValue ?? "2025-11-21"
    AppLogger.mcp.info(
      "[MCPAppHost] initialize resource=\(self.resource.resource.uri, privacy: .public) server=\(self.resource.serverName, privacy: .public) source=\(self.resource.source.rawValue, privacy: .public) protocol=\(protocolVersion, privacy: .public)"
    )
    let hostInfo: AgentHubMCPUIJSONValue = .object([
      "name": .string("AgentHub"),
      "version": .string("1.0.0")
    ])
    let hostCapabilities = hostCapabilitiesValue()
    let hostContext = hostContextValue()

    return .object([
      "protocolVersion": .string(protocolVersion),
      "hostInfo": hostInfo,
      "hostCapabilities": hostCapabilities,
      "hostContext": hostContext,
      "host": hostInfo,
      "capabilities": .object([
        "tools": .object(["call": .bool(resource.source == .liveDiscovery)]),
        "resources": .object(["read": .bool(true), "list": .bool(true)]),
        "openLinks": .object(["enabled": .bool(resource.resource.metadata.permissions.allowOpenLinks)]),
        "logging": .object([:]),
        "display": .object(["sizeChanges": .bool(true)])
      ]),
      "context": hostContext
    ])
  }

  func callTool(
    name: String,
    arguments: AgentHubMCPUIJSONValue?
  ) async throws -> AgentHubMCPUIJSONValue {
    do {
      AppLogger.mcp.info(
        "[MCPAppHost] tool call requested server=\(self.resource.serverName, privacy: .public) tool=\(name, privacy: .public) source=\(self.resource.source.rawValue, privacy: .public)"
      )
      guard resource.source == .liveDiscovery else {
        throw AgentHubMCPUIBridgeError.permissionDenied("Inline MCP app resources cannot call tools without a resolved server.")
      }
      if let allowed = resource.resource.metadata.permissions.allowedToolNames,
         !allowed.contains(name) {
        throw AgentHubMCPUIBridgeError.permissionDenied("MCP app is not allowed to call tool '\(name)'.")
      }
      try await consentController.require(.callTool(name), resource: resource)
      guard let viewModel else {
        throw AgentHubMCPUIBridgeError.invalidRequest("AgentHub session view model is unavailable.")
      }
      let result = try await viewModel.callMCPAppTool(resource: resource, name: name, arguments: arguments)
      AppLogger.mcp.info(
        "[MCPAppHost] tool call done server=\(self.resource.serverName, privacy: .public) tool=\(name, privacy: .public)"
      )
      return result
    } catch {
      AppLogger.mcp.error(
        "[MCPAppHost] tool call failed server=\(self.resource.serverName, privacy: .public) tool=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      report(error: error, deniedTitle: "Tool Call Denied", failureTitle: "Tool Call Failed")
      throw error
    }
  }

  func readResource(uri: String) async throws -> AgentHubMCPUIJSONValue {
    do {
      AppLogger.mcp.info(
        "[MCPAppHost] resource read requested server=\(self.resource.serverName, privacy: .public) uri=\(uri, privacy: .public) source=\(self.resource.source.rawValue, privacy: .public)"
      )
      try await consentController.require(.readResource(uri), resource: resource)
      if uri == resource.resource.uri {
        AppLogger.mcp.info(
          "[MCPAppHost] resource read served from panel resource uri=\(uri, privacy: .public)"
        )
        return .object([
          "contents": .array([resourceContentValue(resource.resource)])
        ])
      }
      guard resource.source == .liveDiscovery, let viewModel else {
        throw AgentHubMCPUIBridgeError.permissionDenied("MCP app cannot read resources without a resolved server.")
      }
      let result = try await viewModel.readMCPAppResource(resource: resource, uri: uri)
      AppLogger.mcp.info(
        "[MCPAppHost] resource read done server=\(self.resource.serverName, privacy: .public) uri=\(uri, privacy: .public)"
      )
      return result
    } catch {
      AppLogger.mcp.error(
        "[MCPAppHost] resource read failed server=\(self.resource.serverName, privacy: .public) uri=\(uri, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      report(error: error, deniedTitle: "Resource Read Denied", failureTitle: "Resource Read Failed")
      throw error
    }
  }

  func listResources() async throws -> AgentHubMCPUIJSONValue {
    do {
      AppLogger.mcp.info(
        "[MCPAppHost] resources list requested server=\(self.resource.serverName, privacy: .public) source=\(self.resource.source.rawValue, privacy: .public)"
      )
      try await consentController.require(.listResources, resource: resource)
      guard resource.source == .liveDiscovery, let viewModel else {
        AppLogger.mcp.info(
          "[MCPAppHost] resources list served from panel resource server=\(self.resource.serverName, privacy: .public)"
        )
        return .object([
          "resources": .array([resourceListValue(resource.resource)])
        ])
      }
      let result = try await viewModel.listMCPAppResources(resource: resource)
      AppLogger.mcp.info(
        "[MCPAppHost] resources list done server=\(self.resource.serverName, privacy: .public)"
      )
      return result
    } catch {
      AppLogger.mcp.error(
        "[MCPAppHost] resources list failed server=\(self.resource.serverName, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      report(error: error, deniedTitle: "Resource List Denied", failureTitle: "Resource List Failed")
      throw error
    }
  }

  func openLink(url: URL) async throws {
    do {
      AppLogger.mcp.info(
        "[MCPAppHost] open link requested url=\(self.redactedURLDescription(url), privacy: .public) resource=\(self.resource.resource.uri, privacy: .public)"
      )
      guard resource.resource.metadata.permissions.allowOpenLinks else {
        throw AgentHubMCPUIBridgeError.permissionDenied("MCP app is not allowed to open external links.")
      }
      guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        throw AgentHubMCPUIBridgeError.permissionDenied("MCP app may only open http or https links.")
      }
      try await consentController.require(.openLink(url), resource: resource)
      NSWorkspace.shared.open(url)
      AppLogger.mcp.info(
        "[MCPAppHost] open link done url=\(self.redactedURLDescription(url), privacy: .public)"
      )
    } catch {
      AppLogger.mcp.error(
        "[MCPAppHost] open link failed url=\(self.redactedURLDescription(url), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
      report(error: error, deniedTitle: "Link Open Denied", failureTitle: "Link Open Failed")
      throw error
    }
  }

  func appDidRequestSize(width: Double?, height: Double?) {
    AppLogger.mcp.debug(
      "[MCPAppHost] size requested resource=\(self.resource.resource.uri, privacy: .public) width=\(width ?? -1, privacy: .public) height=\(height ?? -1, privacy: .public)"
    )
    onSizeChange(width, height)
  }

  func appDidRequestTeardown() {
    AppLogger.mcp.info(
      "[MCPAppHost] teardown requested resource=\(self.resource.resource.uri, privacy: .public)"
    )
    onTeardown()
  }

  func appDidSendMessage(_ params: AgentHubMCPUIJSONValue?) {
    AppLogger.mcp.info(
      "[MCPAppHost] app message resource=\(self.resource.resource.uri, privacy: .public)"
    )
  }

  func appDidUpdateModelContext(_ params: AgentHubMCPUIJSONValue?) {
    AppLogger.mcp.info(
      "[MCPAppHost] model context update resource=\(self.resource.resource.uri, privacy: .public)"
    )
  }

  func appDidLogMessage(_ params: AgentHubMCPUIJSONValue?) {
    AppLogger.mcp.info(
      "[MCPAppHost] app log notification resource=\(self.resource.resource.uri, privacy: .public)"
    )
  }

  private func hostCapabilitiesValue() -> AgentHubMCPUIJSONValue {
    var capabilities: [String: AgentHubMCPUIJSONValue] = [
      "serverTools": .object(["listChanged": .bool(false)]),
      "serverResources": .object(["listChanged": .bool(false)]),
      "logging": .object([:]),
      "sandbox": .object([
        "permissions": sandboxPermissionsValue(resource.resource.metadata.permissions),
        "csp": sdkCSPValue(resource.resource.metadata.csp)
      ]),
      "updateModelContext": .object([
        "text": .object([:]),
        "structuredContent": .object([:])
      ]),
      "message": .object([
        "text": .object([:])
      ])
    ]
    if resource.resource.metadata.permissions.allowOpenLinks {
      capabilities["openLinks"] = .object([:])
    }
    return .object(capabilities)
  }

  private func sandboxPermissionsValue(_ permissions: AgentHubMCPUIPermissions) -> AgentHubMCPUIJSONValue {
    var values: [String: AgentHubMCPUIJSONValue] = [:]
    if permissions.allowCamera {
      values["camera"] = .object([:])
    }
    if permissions.allowMicrophone {
      values["microphone"] = .object([:])
    }
    if permissions.allowGeolocation {
      values["geolocation"] = .object([:])
    }
    return .object(values)
  }

  private func hostContextValue() -> AgentHubMCPUIJSONValue {
    let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return .object([
      "provider": .string(resource.provider.rawValue),
      "projectPath": .string(resource.projectPath),
      "serverName": .string(resource.serverName),
      "resourceUri": .string(resource.resource.uri),
      "theme": .string(isDark ? "dark" : "light"),
      "displayMode": .string("inline"),
      "availableDisplayModes": .array([.string("inline"), .string("fullscreen")]),
      "platform": .string("desktop"),
      "userAgent": .string("AgentHub/1.0.0")
    ])
  }

  private func report(error: Error, deniedTitle: String, failureTitle: String) {
    let isDenied: Bool
    if case .permissionDenied(_) = error as? AgentHubMCPUIBridgeError {
      isDenied = true
    } else {
      isDenied = false
    }
    AppLogger.mcp.error(
      "[MCPAppHost] notice title=\(isDenied ? deniedTitle : failureTitle, privacy: .public) message=\(error.localizedDescription, privacy: .public)"
    )
    onOperationNotice(MCPAppPanelNotice(
      kind: isDenied ? .denied : .error,
      title: isDenied ? deniedTitle : failureTitle,
      message: error.localizedDescription
    ))
  }

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
        "csp": metadataCSPValue(metadata.csp)
      ])
    ])
  }

  private func metadataCSPValue(_ csp: AgentHubMCPUICSP) -> AgentHubMCPUIJSONValue {
    .object([
      "connect_domains": .array(csp.connectDomains.map { .string($0) }),
      "resource_domains": .array(csp.resourceDomains.map { .string($0) })
    ])
  }

  private func sdkCSPValue(_ csp: AgentHubMCPUICSP) -> AgentHubMCPUIJSONValue {
    .object([
      "connectDomains": .array(csp.connectDomains.map { .string($0) }),
      "resourceDomains": .array(csp.resourceDomains.map { .string($0) })
    ])
  }

  private func redactedURLDescription(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.fragment = nil
    return components?.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")"
  }
}
