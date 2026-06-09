//
//  AgentHubMCPUIResourceView.swift
//  AgentHubMCPUI
//

import SwiftUI
import WebKit
import os

private let mcpUILogger = Logger(subsystem: "com.agenthub", category: "MCPUI")

public struct AgentHubMCPUIResourceView: View {
  private let resource: AgentHubMCPUIResource
  private let bridgeHandler: (any AgentHubMCPUIBridgeHandler)?

  public init(
    resource: AgentHubMCPUIResource,
    bridgeHandler: (any AgentHubMCPUIBridgeHandler)? = nil
  ) {
    self.resource = resource
    self.bridgeHandler = bridgeHandler
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text(resource.uri)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer()

        Text(resource.mimeType)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(
            Capsule()
              .fill(Color.secondary.opacity(0.12))
        )
      }

      AgentHubMCPUIWebView(resource: resource, bridgeHandler: bridgeHandler)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
  }
}

@MainActor
public protocol AgentHubMCPUIBridgeHandler: AnyObject {
  func initialize(params: AgentHubMCPUIJSONValue?) async throws -> AgentHubMCPUIJSONValue
  func callTool(name: String, arguments: AgentHubMCPUIJSONValue?) async throws -> AgentHubMCPUIJSONValue
  func readResource(uri: String) async throws -> AgentHubMCPUIJSONValue
  func listResources() async throws -> AgentHubMCPUIJSONValue
  func openLink(url: URL) async throws
  func appDidRequestSize(width: Double?, height: Double?)
  func appDidRequestTeardown()
  func appDidSendMessage(_ params: AgentHubMCPUIJSONValue?)
  func appDidUpdateModelContext(_ params: AgentHubMCPUIJSONValue?)
  func appDidLogMessage(_ params: AgentHubMCPUIJSONValue?)
}

public extension AgentHubMCPUIBridgeHandler {
  func initialize(params: AgentHubMCPUIJSONValue?) async throws -> AgentHubMCPUIJSONValue {
    let protocolVersion = params?["protocolVersion"]?.stringValue ?? "2025-11-21"
    let hostInfo: AgentHubMCPUIJSONValue = .object([
      "name": .string("AgentHub"),
      "version": .string("1.0.0")
    ])
    let hostCapabilities: AgentHubMCPUIJSONValue = .object([
      "serverTools": .object([:]),
      "serverResources": .object([:]),
      "openLinks": .object([:]),
      "logging": .object([:]),
      "updateModelContext": .object([
        "text": .object([:]),
        "structuredContent": .object([:])
      ]),
      "message": .object([
        "text": .object([:])
      ])
    ])
    let hostContext: AgentHubMCPUIJSONValue = .object([
      "displayMode": .string("inline"),
      "availableDisplayModes": .array([.string("inline"), .string("fullscreen")]),
      "platform": .string("desktop"),
      "userAgent": .string("AgentHub/1.0.0")
    ])

    return .object([
      "protocolVersion": .string(protocolVersion),
      "hostInfo": hostInfo,
      "hostCapabilities": hostCapabilities,
      "hostContext": hostContext,
      "host": hostInfo,
      "capabilities": .object([
        "tools": .object(["call": .bool(true)]),
        "resources": .object(["read": .bool(true), "list": .bool(true)]),
        "openLinks": .object([:]),
        "logging": .object([:]),
        "display": .object(["sizeChanges": .bool(true)])
      ]),
      "context": hostContext
    ])
  }

  func readResource(uri: String) async throws -> AgentHubMCPUIJSONValue {
    throw AgentHubMCPUIBridgeError.unsupportedMethod("resources/read")
  }

  func listResources() async throws -> AgentHubMCPUIJSONValue {
    throw AgentHubMCPUIBridgeError.unsupportedMethod("resources/list")
  }

  func appDidRequestSize(width: Double?, height: Double?) {}
  func appDidRequestTeardown() {}
  func appDidSendMessage(_ params: AgentHubMCPUIJSONValue?) {}
  func appDidUpdateModelContext(_ params: AgentHubMCPUIJSONValue?) {}
  func appDidLogMessage(_ params: AgentHubMCPUIJSONValue?) {}
}

public enum AgentHubMCPUIBridgeError: LocalizedError {
  case unsupportedMethod(String)
  case invalidRequest(String)
  case permissionDenied(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedMethod(let method):
      return "Unsupported MCP app method: \(method)"
    case .invalidRequest(let message), .permissionDenied(let message):
      return message
    }
  }
}

public struct AgentHubMCPUIWebView: NSViewRepresentable {
  private let resource: AgentHubMCPUIResource
  private let bridgeHandler: (any AgentHubMCPUIBridgeHandler)?

  public init(
    html: String,
    bridgeHandler: (any AgentHubMCPUIBridgeHandler)? = nil
  ) {
    self.resource = AgentHubMCPUIResource(uri: "ui://agenthub/inline", text: html)
    self.bridgeHandler = bridgeHandler
  }

  public init(
    resource: AgentHubMCPUIResource,
    bridgeHandler: (any AgentHubMCPUIBridgeHandler)? = nil
  ) {
    self.resource = resource
    self.bridgeHandler = bridgeHandler
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(bridgeHandler: bridgeHandler)
  }

  public func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(
      context.coordinator,
      name: Coordinator.scriptMessageHandlerName
    )
    configuration.userContentController.addUserScript(Coordinator.bridgeBootstrapScript())

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.setValue(false, forKey: "drawsBackground")
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    context.coordinator.webView = webView
    mcpUILogger.info(
      "[MCPUIBridge] load resource uri=\(resource.uri, privacy: .public) mime=\(resource.mimeType, privacy: .public)"
    )
    webView.loadHTMLString(Self.hardenedHTML(for: resource), baseURL: Self.baseURL(for: resource))
    context.coordinator.loadedResource = resource
    return webView
  }

  public func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.bridgeHandler = bridgeHandler
    guard context.coordinator.loadedResource != resource else { return }
    mcpUILogger.info(
      "[MCPUIBridge] reload resource uri=\(resource.uri, privacy: .public) mime=\(resource.mimeType, privacy: .public)"
    )
    webView.loadHTMLString(Self.hardenedHTML(for: resource), baseURL: Self.baseURL(for: resource))
    context.coordinator.loadedResource = resource
  }

  public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.sendNotification(method: "ui/resource-teardown", params: .object([
      "uri": .string(coordinator.loadedResource?.uri ?? "")
    ]))
    mcpUILogger.info(
      "[MCPUIBridge] dismantle resource uri=\(coordinator.loadedResource?.uri ?? "unknown", privacy: .public)"
    )
    webView.configuration.userContentController.removeScriptMessageHandler(
      forName: Coordinator.scriptMessageHandlerName
    )
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
  }

  private static func baseURL(for resource: AgentHubMCPUIResource) -> URL {
    URL(string: "agenthub-mcp-app://local/")!
  }

  private static func hardenedHTML(for resource: AgentHubMCPUIResource) -> String {
    let csp = cspContent(for: resource.metadata.csp)
    let meta = #"<meta http-equiv="Content-Security-Policy" content="\#(AgentHubMCPUIHTML.escape(csp))">"#
    if let headRange = resource.text.range(of: "<head", options: [.caseInsensitive]),
       let close = resource.text[headRange.lowerBound...].firstIndex(of: ">") {
      var html = resource.text
      html.insert(contentsOf: meta, at: html.index(after: close))
      return html
    }
    return """
    <!doctype html>
    <html>
    <head>\(meta)</head>
    <body>\(resource.text)</body>
    </html>
    """
  }

  private static func cspContent(for csp: AgentHubMCPUICSP) -> String {
    let connect = domainSources(csp.connectDomains)
    let resources = domainSources(csp.resourceDomains)
    return [
      "default-src 'none'",
      "base-uri 'none'",
      "form-action 'none'",
      "frame-ancestors 'none'",
      "script-src 'unsafe-inline' \(resources)",
      "style-src 'unsafe-inline' \(resources)",
      "img-src data: blob: \(resources)",
      "font-src data: \(resources)",
      "connect-src \(connect)",
      "media-src \(resources)"
    ].joined(separator: "; ")
  }

  private static func domainSources(_ domains: [String]) -> String {
    let sanitized = domains.compactMap { domain -> String? in
      let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      if trimmed == "'self'" || trimmed == "self" {
        return "'self'"
      }
      guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            (scheme == "https" || scheme == "http"), url.host != nil else {
        return nil
      }
      return trimmed
    }
    return sanitized.joined(separator: " ")
  }

  @MainActor
  public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let scriptMessageHandlerName = "agentHubMCPApp"

    weak var webView: WKWebView?
    weak var bridgeHandler: (any AgentHubMCPUIBridgeHandler)?
    var loadedResource: AgentHubMCPUIResource?

    init(bridgeHandler: (any AgentHubMCPUIBridgeHandler)?) {
      self.bridgeHandler = bridgeHandler
    }

    public func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == Self.scriptMessageHandlerName else { return }
      let body: Any
      if let string = message.body as? String,
         let data = string.data(using: .utf8),
         let json = try? JSONSerialization.jsonObject(with: data) {
        body = json
      } else {
        body = message.body
      }

      guard let envelope = AgentHubMCPUIJSONValue.fromJSONObject(body).objectValue else {
        mcpUILogger.error("[MCPUIBridge] invalid native message body")
        sendError(id: nil, code: -32600, message: "Invalid JSON-RPC message")
        return
      }

      mcpUILogger.debug(
        "[MCPUIBridge] app->host raw method=\(envelope["method"]?.stringValue ?? "response", privacy: .public) id=\(Self.idDescription(envelope["id"]), privacy: .public) resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public)"
      )

      Task { @MainActor in
        await handleMessage(envelope)
      }
    }

    public func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard navigationAction.navigationType != .other else {
        decisionHandler(.allow)
        return
      }

      if let url = navigationAction.request.url, isExternalHTTPURL(url) {
        mcpUILogger.info(
          "[MCPUIBridge] external navigation requested url=\(Self.redactedURLDescription(url), privacy: .public)"
        )
        Task { @MainActor in
          try? await bridgeHandler?.openLink(url: url)
        }
      }
      decisionHandler(.cancel)
    }

    public func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if let url = navigationAction.request.url, isExternalHTTPURL(url) {
        mcpUILogger.info(
          "[MCPUIBridge] new-window navigation requested url=\(Self.redactedURLDescription(url), privacy: .public)"
        )
        Task { @MainActor in
          try? await bridgeHandler?.openLink(url: url)
        }
      }
      return nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      mcpUILogger.info(
        "[MCPUIBridge] navigation finished resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public)"
      )
    }

    public func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation!,
      withError error: Error
    ) {
      mcpUILogger.error(
        "[MCPUIBridge] navigation failed resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
    }

    public func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      mcpUILogger.error(
        "[MCPUIBridge] provisional navigation failed resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
      )
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      mcpUILogger.error(
        "[MCPUIBridge] web content process terminated resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public)"
      )
    }

    func sendNotification(method: String, params: AgentHubMCPUIJSONValue?) {
      let message: AgentHubMCPUIJSONValue = .object([
        "jsonrpc": .string("2.0"),
        "method": .string(method),
        "params": params ?? .null
      ])
      mcpUILogger.debug(
        "[MCPUIBridge] host->app notification method=\(method, privacy: .public) resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public)"
      )
      sendToApp(message)
    }

    static func bridgeBootstrapScript() -> WKUserScript {
      let source = """
      (function() {
        if (window.__agentHubMCPBridgeInstalled) return;
        window.__agentHubMCPBridgeInstalled = true;
        const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(scriptMessageHandlerName);
        const originalPostMessage = window.postMessage ? window.postMessage.bind(window) : null;
        const hostOrigin = 'agenthub://host';

        function parseJSONRPC(message) {
          if (!message) return null;
          if (typeof message === 'string') {
            try { message = JSON.parse(message); } catch (error) { return null; }
          }
          if (typeof message !== 'object' || message.jsonrpc !== '2.0') return null;
          if (!message.method) return null;
          return message;
        }

        function forwardToNative(message) {
          const rpc = parseJSONRPC(message);
          if (!rpc || !native) return false;
          native.postMessage(JSON.stringify(rpc));
          return true;
        }

        window.__agentHubMCPReceive = function(message) {
          const event = new MessageEvent('message', {
            data: message,
            origin: hostOrigin,
            source: window
          });
          window.dispatchEvent(event);
        };

        window.postMessage = function(message, targetOrigin) {
          if (forwardToNative(message)) {
            return;
          }
          if (originalPostMessage) {
            return originalPostMessage(message, targetOrigin);
          }
        };

        window.addEventListener('message', function(event) {
          if (event.origin === hostOrigin) return;
          forwardToNative(event.data);
        }, true);
      })();
      """
      return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    private func handleMessage(_ envelope: [String: AgentHubMCPUIJSONValue]) async {
      guard envelope["jsonrpc"]?.stringValue == "2.0" else {
        mcpUILogger.error("[MCPUIBridge] invalid JSON-RPC version")
        sendError(id: envelope["id"], code: -32600, message: "Invalid JSON-RPC version")
        return
      }

      guard let method = envelope["method"]?.stringValue else {
        mcpUILogger.error("[MCPUIBridge] missing method")
        sendError(id: envelope["id"], code: -32600, message: "Missing method")
        return
      }

      let id = envelope["id"]
      let params = envelope["params"]
      let started = Date()
      mcpUILogger.info(
        "[MCPUIBridge] handle start method=\(method, privacy: .public) id=\(Self.idDescription(id), privacy: .public) resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public)"
      )

      do {
        if let result = try await handle(method: method, params: params) {
          if let id {
            sendResult(id: id, result: result)
          }
        } else if let id {
          sendResult(id: id, result: .object([:]))
        }
        let elapsed = Date().timeIntervalSince(started)
        mcpUILogger.info(
          "[MCPUIBridge] handle done method=\(method, privacy: .public) id=\(Self.idDescription(id), privacy: .public) elapsed=\(elapsed, privacy: .public)"
        )
      } catch {
        let elapsed = Date().timeIntervalSince(started)
        mcpUILogger.error(
          "[MCPUIBridge] handle failed method=\(method, privacy: .public) id=\(Self.idDescription(id), privacy: .public) elapsed=\(elapsed, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
        if let id {
          sendError(id: id, code: -32000, message: error.localizedDescription)
        }
      }
    }

    private func handle(
      method: String,
      params: AgentHubMCPUIJSONValue?
    ) async throws -> AgentHubMCPUIJSONValue? {
      switch method {
      case "initialize", "ui/initialize":
        return try await bridgeHandler?.initialize(params: params)
      case "ping":
        return .object([:])
      case "tools/call":
        guard let object = params?.objectValue,
              let name = object["name"]?.stringValue else {
          throw AgentHubMCPUIBridgeError.invalidRequest("MCP app tool call is missing a tool name.")
        }
        return try await bridgeHandler?.callTool(name: name, arguments: object["arguments"])
      case "resources/read":
        guard let uri = params?["uri"]?.stringValue else {
          throw AgentHubMCPUIBridgeError.invalidRequest("MCP app resource read is missing a URI.")
        }
        return try await bridgeHandler?.readResource(uri: uri)
      case "resources/list":
        return try await bridgeHandler?.listResources()
      case "ui/open-link", "openLink":
        guard let object = params?.objectValue,
              let rawURL = object["url"]?.stringValue ?? object["href"]?.stringValue,
              let url = URL(string: rawURL),
              isExternalHTTPURL(url) else {
          throw AgentHubMCPUIBridgeError.invalidRequest("MCP app requested an invalid link.")
        }
        try await bridgeHandler?.openLink(url: url)
        return .object([:])
      case "ui/request-display-mode":
        let requestedMode = params?["mode"]?.stringValue ?? "inline"
        let supportedMode = requestedMode == "fullscreen" ? "fullscreen" : "inline"
        return .object(["mode": .string(supportedMode)])
      case "ui/message":
        bridgeHandler?.appDidSendMessage(params)
        return .object([:])
      case "ui/update-model-context", "ui/updateModelContext":
        bridgeHandler?.appDidUpdateModelContext(params)
        return .object([:])
      case "notifications/message", "ui/notifications/message":
        bridgeHandler?.appDidLogMessage(params)
        return nil
      case "ui/notifications/initialized":
        return nil
      case "ui/notifications/size-changed", "ui/size-changed":
        let object = params?.objectValue
        bridgeHandler?.appDidRequestSize(
          width: object?["width"]?.numberValue,
          height: object?["height"]?.numberValue
        )
        return nil
      case "ui/notifications/request-teardown", "ui/request-teardown", "ui/teardown":
        bridgeHandler?.appDidRequestTeardown()
        return nil
      default:
        throw AgentHubMCPUIBridgeError.unsupportedMethod(method)
      }
    }

    private func sendResult(id: AgentHubMCPUIJSONValue, result: AgentHubMCPUIJSONValue) {
      mcpUILogger.debug(
        "[MCPUIBridge] host->app result id=\(Self.idDescription(id), privacy: .public) resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public)"
      )
      sendToApp(.object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": result
      ]))
    }

    private func sendError(id: AgentHubMCPUIJSONValue?, code: Int, message: String) {
      mcpUILogger.error(
        "[MCPUIBridge] host->app error id=\(Self.idDescription(id), privacy: .public) code=\(code, privacy: .public) message=\(message, privacy: .public) resource=\(self.loadedResource?.uri ?? "unknown", privacy: .public)"
      )
      var envelope: [String: AgentHubMCPUIJSONValue] = [
        "jsonrpc": .string("2.0"),
        "error": .object([
          "code": .number(Double(code)),
          "message": .string(message)
        ])
      ]
      if let id {
        envelope["id"] = id
      }
      sendToApp(.object(envelope))
    }

    private func sendToApp(_ message: AgentHubMCPUIJSONValue) {
      guard let webView else { return }
      guard let data = try? JSONEncoder().encode(message),
            let json = String(data: data, encoding: .utf8) else {
        mcpUILogger.error("[MCPUIBridge] failed to encode host message")
        return
      }
      webView.evaluateJavaScript("window.__agentHubMCPReceive && window.__agentHubMCPReceive(\(json));") { _, error in
        if let error {
          mcpUILogger.error(
            "[MCPUIBridge] failed to deliver host message error=\(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }

    private func isExternalHTTPURL(_ url: URL) -> Bool {
      guard let scheme = url.scheme?.lowercased() else { return false }
      return scheme == "http" || scheme == "https"
    }

    private static func redactedURLDescription(_ url: URL) -> String {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      components?.query = nil
      components?.fragment = nil
      return components?.string ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")"
    }

    private static func idDescription(_ id: AgentHubMCPUIJSONValue?) -> String {
      guard let id else { return "notification" }
      if let string = id.stringValue { return string }
      if let number = id.numberValue { return String(number) }
      return "unknown"
    }
  }
}

private extension AgentHubMCPUIJSONValue {
  var numberValue: Double? {
    if case .number(let value) = self {
      return value
    }
    return nil
  }
}
