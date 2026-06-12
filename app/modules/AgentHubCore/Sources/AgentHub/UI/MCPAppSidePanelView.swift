//
//  MCPAppSidePanelView.swift
//  AgentHub
//
//  Embedded side panel that renders MCP app resources surfaced by the agent as
//  tool results (parsed from the session JSONL into
//  `SessionMonitorState.detectedMCPAppResources`). Unlike the removed modal
//  discovery panel, this never spawns MCP servers on its own; it renders the
//  resource the agent produced and routes any in-app callbacks lazily to that
//  one server through the on-demand client gateway.
//

import AgentHubMCPUI
import AppKit
import SwiftUI

// MARK: - MCPAppSidePanelView

/// Side panel host for agent-produced MCP app resources. Reads the live list of
/// detected resources from the session's monitor state so a newly produced
/// resource refreshes an open panel.
struct MCPAppSidePanelView: View {
  let session: CLISession
  let viewModel: CLISessionsViewModel?
  let monitorState: SessionMonitorState?
  let onDismiss: () -> Void

  @State private var selectedItemID: String?
  @State private var consentController = MCPAppConsentController()
  @State private var operationNotice: MCPAppPanelNotice?

  private var items: [MCPAppRenderItem] {
    viewModel?.mcpAppDisplayItems(for: session, state: monitorState) ?? []
  }

  private var itemIDs: [String] {
    items.map(\.id)
  }

  private var selectedItem: MCPAppRenderItem? {
    let selectedID = selectedItemID ?? items.first?.id
    return items.first { $0.id == selectedID } ?? items.first
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      Divider()

      if let operationNotice {
        MCPAppNoticeBanner(notice: operationNotice) {
          self.operationNotice = nil
        }
      }

      if let selectedItem {
        MCPAppResourceHostView(
          resource: selectedItem.resource,
          invocation: selectedItem.invocation,
          viewModel: viewModel,
          consentController: consentController,
          onOperationNotice: { operationNotice = $0 },
          onTeardown: onDismiss
        )
        .id(selectedItem.id)
      } else {
        emptyState
      }
    }
    .frame(
      minWidth: 300, idealWidth: .infinity, maxWidth: .infinity,
      minHeight: 300, idealHeight: .infinity, maxHeight: .infinity
    )
    .onAppear {
      selectedItemID = selectedItemID ?? items.first?.id
    }
    .onChange(of: itemIDs) { previousIDs, currentIDs in
      reconcileSelection(previousIDs: previousIDs, currentIDs: currentIDs)
    }
    .onKeyPress(.escape) {
      onDismiss()
      return .handled
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
      Button("Allow for This Session") {
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

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "square.stack.3d.up")
        .foregroundStyle(Color.brandPrimary)
        .accessibilityHidden(true)

      Text("MCP Apps")
        .font(.headline)

      Spacer(minLength: 12)

      if items.count > 1 {
        Picker("MCP App", selection: Binding(
          get: { selectedItemID ?? items.first?.id },
          set: { selectedItemID = $0 }
        )) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Text(pickerLabel(for: item, at: index))
              .tag(Optional(item.id))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        .accessibilityLabel("Select MCP app")
      }

      Button("Close", action: onDismiss)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var emptyState: some View {
    ContentUnavailableView(
      "No MCP Apps",
      systemImage: "square.stack.3d.up",
      description: Text("This session has not produced an MCP app resource yet.")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Picker label for an item; appends an ordinal when several items share a title
  /// (e.g. successive edits of the same diagram) so they remain distinguishable.
  private func pickerLabel(for item: MCPAppRenderItem, at index: Int) -> String {
    let base = item.resource.title ?? item.resource.resource.metadata.title ?? item.resource.serverName
    let sharesTitle = items.filter { $0.resource.title == item.resource.title }.count > 1
    return sharesTitle ? "\(base) \(index + 1)" : base
  }

  /// Keeps the selection valid as resources arrive/leave. Prefers a freshly
  /// produced resource so the open panel follows the agent's latest output.
  private func reconcileSelection(previousIDs: [String], currentIDs: [String]) {
    let added = Set(currentIDs).subtracting(previousIDs)
    if let newest = currentIDs.last(where: { added.contains($0) }) {
      selectedItemID = newest
      return
    }
    if let selectedItemID, currentIDs.contains(selectedItemID) {
      return
    }
    selectedItemID = currentIDs.first
  }
}

// MARK: - MCPAppNetworkConsent

/// Pure logic for the MCP app network-consent banner. An app's declared CSP
/// domains are untrusted tool output; the web view stays `.lockedDown` until the
/// user explicitly opts in for that one app. These helpers decide what to show
/// and when, and are unit-tested independently of the view.
enum MCPAppNetworkConsent {
  /// Distinct https/http hosts declared in the (untrusted) CSP metadata, in
  /// declaration order. Used to name the domains in the banner — we never render
  /// the raw declared strings, only validated, parsed hosts.
  static func declaredHosts(for csp: AgentHubMCPUICSP) -> [String] {
    var seen = Set<String>()
    var hosts: [String] = []
    for domain in csp.connectDomains + csp.resourceDomains {
      guard let url = URL(string: domain),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = url.host, !host.isEmpty else {
        continue
      }
      if seen.insert(host).inserted {
        hosts.append(host)
      }
    }
    return hosts
  }

  /// Show the consent banner whenever the app declares network hosts and the user
  /// has not yet granted them. (Declining closes the panel rather than leaving the
  /// banner dismissed, so there is no "dismissed but still open" state.)
  static func shouldPrompt(hosts: [String], consented: Bool) -> Bool {
    !hosts.isEmpty && !consented
  }
}

// MARK: - MCPAppResourceHostView

/// Renders a single MCP app resource in a WKWebView and bridges its JSON-RPC
/// messages to the host. Resolves any in-flight consent when the resource
/// changes or the panel disappears so a bridge call never hangs.
private struct MCPAppResourceHostView: View {
  let resource: MCPAppResource
  let invocation: MCPAppInvocation?
  let viewModel: CLISessionsViewModel?
  let consentController: MCPAppConsentController
  let onOperationNotice: (MCPAppPanelNotice) -> Void
  let onTeardown: () -> Void

  @State private var bridgeHandler: MCPAppHostBridgeHandler?
  /// User opted this app's declared domains in during the current panel open.
  @State private var networkConsented = false

  private var declaredHosts: [String] {
    MCPAppNetworkConsent.declaredHosts(for: resource.resource.metadata.csp)
  }

  private var appDisplayName: String {
    resource.title ?? resource.resource.metadata.title ?? resource.serverName
  }

  /// Granted if approved this open (`networkConsented`) or earlier this launch
  /// (persisted on the view model), so reopening an already-approved app renders
  /// with widened CSP immediately — no reload, no banner.
  private var isNetworkGranted: Bool {
    networkConsented
      || (viewModel?.isMCPAppNetworkGranted(serverName: resource.serverName, hosts: declaredHosts) ?? false)
  }

  private var showsNetworkConsentBanner: Bool {
    MCPAppNetworkConsent.shouldPrompt(hosts: declaredHosts, consented: isNetworkGranted)
  }

  var body: some View {
    VStack(spacing: 0) {
      resourceToolbar

      Divider()

      if showsNetworkConsentBanner {
        MCPAppNetworkConsentBanner(
          appName: appDisplayName,
          hosts: declaredHosts,
          onAllow: allowNetwork,
          onDecline: declineNetwork
        )
      }

      AgentHubMCPUIWebView(
        resource: resource.resource,
        bridgeHandler: bridgeHandler,
        networkTrust: isNetworkGranted ? .allowDeclaredDomains : .lockedDown
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear(perform: installBridgeHandler)
    .onChange(of: resource.id) { _, _ in
      handleResourceChange()
    }
    .onDisappear {
      consentController.cancelPending()
    }
  }

  private func allowNetwork() {
    // Persist for this launch so reopening the panel doesn't re-prompt, and flip
    // the local state for an immediate widen on this open.
    viewModel?.grantMCPAppNetwork(serverName: resource.serverName, hosts: declaredHosts)
    networkConsented = true
  }

  /// Declining network closes the panel: an app that declares hosts generally
  /// needs them to render (e.g. it loads its runtime from a CDN), so leaving a
  /// locked-down — often blank — panel open would be useless. Reopening later
  /// asks again (the grant was never given).
  private func declineNetwork() {
    onTeardown()
  }

  /// Switching to a different app drops this-open state; `isNetworkGranted` then
  /// re-derives from any persisted grant for the new app. In-flight consent is
  /// cancelled so a bridge call never hangs across the switch.
  private func handleResourceChange() {
    consentController.cancelPending()
    networkConsented = false
    installBridgeHandler()
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
      invocation: invocation,
      viewModel: viewModel,
      consentController: consentController,
      onSizeChange: { _, _ in },
      onOperationNotice: onOperationNotice,
      onTeardown: onTeardown
    )
  }
}

// MARK: - MCPAppConsentController

@MainActor
@Observable
final class MCPAppConsentController {
  var pendingRequest: MCPAppConsentRequest?

  @ObservationIgnored private var grants: Set<MCPAppConsentGrant> = []
  @ObservationIgnored private var pendingContinuation: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var pendingTimeoutTask: Task<Void, Never>?
  @ObservationIgnored private let autoDenyTimeout: Duration

  init(autoDenyTimeout: Duration = .seconds(45)) {
    self.autoDenyTimeout = autoDenyTimeout
  }

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
      startAutoDenyTimer()
    }

    if allowed {
      grants.insert(grant)
      return
    }

    throw AgentHubMCPUIBridgeError.permissionDenied(action.denialMessage)
  }

  func approvePendingRequest() {
    resolvePending(with: true)
  }

  func denyPendingRequest() {
    resolvePending(with: false)
  }

  /// Resolves any in-flight consent request as denied. Call when the hosting
  /// view disappears or switches resources so the awaiting bridge call returns
  /// instead of hanging forever.
  func cancelPending() {
    resolvePending(with: false)
  }

  private func startAutoDenyTimer() {
    pendingTimeoutTask?.cancel()
    let timeout = autoDenyTimeout
    pendingTimeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      self?.resolvePending(with: false)
    }
  }

  /// Resumes the pending continuation exactly once. Nils the continuation
  /// before resuming so racing callers (user action, timeout, cancel) can't
  /// double-resume.
  private func resolvePending(with allowed: Bool) {
    pendingTimeoutTask?.cancel()
    pendingTimeoutTask = nil
    guard let continuation = pendingContinuation else { return }
    pendingContinuation = nil
    pendingRequest = nil
    continuation.resume(returning: allowed)
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

// MARK: - MCPAppPanelNotice

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

// MARK: - MCPAppNetworkConsentBanner

/// Prominent one-time consent card shown above an MCP app that declares network
/// hosts. The app's declared domains are untrusted, so the web view stays locked
/// down until the user taps Allow here. Because it is seen at most once per app
/// per launch, it presents the decision deliberately: which app, exactly which
/// hosts, and that the grant is remembered for the session.
private struct MCPAppNetworkConsentBanner: View {
  let appName: String
  let hosts: [String]
  let onAllow: () -> Void
  let onDecline: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  private static let visibleHostCap = 4

  private var visibleHosts: [String] { Array(hosts.prefix(Self.visibleHostCap)) }
  private var overflowCount: Int { max(0, hosts.count - Self.visibleHostCap) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "network.badge.shield.half.filled")
          .font(.title3)
          .foregroundStyle(Color.brandPrimary)
          .frame(width: 36, height: 36)
          .background(Color.brandPrimary.opacity(0.12), in: .rect(cornerRadius: 9))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 1) {
          Text("Allow network access?")
            .font(.headline)
          Text(appName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)

        Spacer(minLength: 0)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Connects to")
          .font(.caption)
          .foregroundStyle(.secondary)

        ForEach(visibleHosts, id: \.self) { host in
          Label {
            Text(host)
              .font(.callout.monospaced())
              .lineLimit(1)
              .truncationMode(.middle)
          } icon: {
            Image(systemName: "globe")
              .foregroundStyle(.secondary)
          }
        }

        if overflowCount > 0 {
          Text("+\(overflowCount) more")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Connects to \(hosts.joined(separator: ", "))")

      Text("Blocked until you allow · kept for this session")
        .font(.caption)
        .foregroundStyle(.tertiary)

      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Not Now", action: onDecline)
        Button("Allow", action: onAllow)
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(14)
    .background(.regularMaterial, in: .rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.brandPrimary.opacity(0.25), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    // Gentle reveal for a deliberate, one-time prompt; instant under Reduce Motion.
    .opacity(appeared ? 1 : 0)
    .offset(y: appeared ? 0 : -6)
    .onAppear {
      guard !appeared else { return }
      if reduceMotion {
        appeared = true
      } else {
        withAnimation(.smooth(duration: 0.28)) { appeared = true }
      }
    }
  }
}

// MARK: - MCPAppHostBridgeHandler

@MainActor
final class MCPAppHostBridgeHandler: AgentHubMCPUIBridgeHandler {
  private let resource: MCPAppResource
  /// The agent tool call that produced this app, pushed to the app on init so it renders.
  private let invocation: MCPAppInvocation?
  private weak var viewModel: CLISessionsViewModel?
  private let consentController: MCPAppConsentController
  private let onSizeChange: (Double?, Double?) -> Void
  private let onOperationNotice: (MCPAppPanelNotice) -> Void
  private let onTeardown: () -> Void

  init(
    resource: MCPAppResource,
    invocation: MCPAppInvocation? = nil,
    viewModel: CLISessionsViewModel?,
    consentController: MCPAppConsentController,
    onSizeChange: @escaping (Double?, Double?) -> Void,
    onOperationNotice: @escaping (MCPAppPanelNotice) -> Void,
    onTeardown: @escaping () -> Void
  ) {
    self.resource = resource
    self.invocation = invocation
    self.viewModel = viewModel
    self.consentController = consentController
    self.onSizeChange = onSizeChange
    self.onOperationNotice = onOperationNotice
    self.onTeardown = onTeardown
  }

  func appReadyNotifications() -> [AgentHubMCPUIOutgoingNotification] {
    guard let invocation else { return [] }
    return [
      AgentHubMCPUIOutgoingNotification(
        method: "ui/notifications/tool-input",
        params: .object(["arguments": invocation.arguments ?? .object([:])])
      ),
      AgentHubMCPUIOutgoingNotification(
        method: "ui/notifications/tool-result",
        params: Self.toolResultParams(from: invocation.result)
      )
    ]
  }

  /// Shapes a captured tool result into the MCP Apps `tool-result` payload the app
  /// expects (`{ content, structuredContent }`). Claude Code stores the result as a
  /// JSON string, so we parse it into `structuredContent` (e.g. `{checkpointId}`).
  static func toolResultParams(from result: AgentHubMCPUIJSONValue?) -> AgentHubMCPUIJSONValue {
    guard let result else {
      return .object(["content": .array([]), "structuredContent": .object([:])])
    }
    switch result {
    case .string(let text):
      let structured = parseJSONObject(text) ?? .object([:])
      return .object([
        "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        "structuredContent": structured
      ])
    case .object(let object):
      // Already a full MCP result with structuredContent — pass through.
      if object["structuredContent"] != nil {
        return result
      }
      // Has content blocks (e.g. Codex's Ok-wrapped result) but no structuredContent —
      // derive structuredContent by parsing the first JSON text block.
      if let content = object["content"] {
        var structured: AgentHubMCPUIJSONValue = .object([:])
        if case .array(let blocks) = content {
          for block in blocks {
            if let text = block["text"]?.stringValue, let parsed = parseJSONObject(text) {
              structured = parsed
              break
            }
          }
        }
        return .object(["content": content, "structuredContent": structured])
      }
      // A bare structured object — treat it as structuredContent.
      return .object(["content": .array([]), "structuredContent": result])
    case .array(let blocks):
      var structured: AgentHubMCPUIJSONValue = .object([:])
      for block in blocks {
        if let text = block["text"]?.stringValue, let parsed = parseJSONObject(text) {
          structured = parsed
          break
        }
      }
      return .object(["content": result, "structuredContent": structured])
    default:
      return .object(["content": .array([]), "structuredContent": .object([:])])
    }
  }

  private static func parseJSONObject(_ text: String) -> AgentHubMCPUIJSONValue? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          object is [String: Any] else {
      return nil
    }
    return AgentHubMCPUIJSONValue(any: object)
  }

  /// Whether this resource can route in-app callbacks to a real MCP server.
  /// Inline resources surfaced from JSONL carry the server name derived from the
  /// `mcp__<server>__<tool>` tool name, so they resolve lazily through the
  /// on-demand client gateway. Resources without a resolvable server render
  /// static HTML and fast-fail any callbacks (no timeout, no hang).
  private var canResolveServer: Bool {
    viewModel != nil && !resource.serverName.isEmpty && resource.serverName != "inline"
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
        "tools": .object(["call": .bool(canResolveServer)]),
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
      guard canResolveServer else {
        throw AgentHubMCPUIBridgeError.permissionDenied("This MCP app has no resolvable MCP server to call tools on.")
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
      guard canResolveServer, let viewModel else {
        throw AgentHubMCPUIBridgeError.permissionDenied("MCP app cannot read resources without a resolvable server.")
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
      guard canResolveServer, let viewModel else {
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
