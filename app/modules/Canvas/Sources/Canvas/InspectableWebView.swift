//
//  InspectableWebView.swift
//  WebInspector
//
//  Reusable NSViewRepresentable wrapping WKWebView with built-in
//  element inspector support. Supports both localhost and file URLs.
//

import SwiftUI
import WebKit

// MARK: - InspectableWebView

/// Wraps a `WKWebView` for rendering web content with built-in element inspector support.
///
/// For file URLs, uses `loadFileURL(_:allowingReadAccessTo:)` so relative assets (CSS, JS, images)
/// resolve correctly within the project directory.
///
/// The inspector overlay (hover highlight, click capture) is injected automatically.
/// Control it via `isInspectModeActive` and receive click data via `onElementSelected`.
public struct InspectableWebView: NSViewRepresentable {
  public let url: URL
  public let isFileURL: Bool
  /// Directory to grant read access for file URLs (typically the project root)
  public let allowingReadAccessTo: URL?
  public var onLoadingChange: ((Bool) -> Void)?
  public var onURLChange: ((URL?) -> Void)?
  public let onError: ((String) -> Void)?
  /// Change this token to force a reload (useful for file:// URLs that don't change path)
  public var reloadToken: UUID? = nil
  /// Called when the user clicks an element in inspect mode
  public var onElementSelected: ((ElementInspectorData) -> Void)?
  /// Called when the selected element's viewport rect changes due to scrolling or resizing.
  public var onSelectedElementViewportRectChange: ((CGRect) -> Void)?
  /// Binding controlling whether the JS inspector overlay is active
  public var isInspectModeActive: Binding<Bool>?
  /// ID of the currently selected element; nil means no selection (clears JS lock)
  public var selectedElementId: UUID? = nil

  public init(
    url: URL,
    isFileURL: Bool,
    allowingReadAccessTo: URL? = nil,
    onLoadingChange: ((Bool) -> Void)? = nil,
    onURLChange: ((URL?) -> Void)? = nil,
    onError: ((String) -> Void)? = nil,
    reloadToken: UUID? = nil,
    onElementSelected: ((ElementInspectorData) -> Void)? = nil,
    onSelectedElementViewportRectChange: ((CGRect) -> Void)? = nil,
    isInspectModeActive: Binding<Bool>? = nil,
    selectedElementId: UUID? = nil
  ) {
    self.url = url
    self.isFileURL = isFileURL
    self.allowingReadAccessTo = allowingReadAccessTo
    self.onLoadingChange = onLoadingChange
    self.onURLChange = onURLChange
    self.onError = onError
    self.reloadToken = reloadToken
    self.onElementSelected = onElementSelected
    self.onSelectedElementViewportRectChange = onSelectedElementViewportRectChange
    self.isInspectModeActive = isInspectModeActive
    self.selectedElementId = selectedElementId
  }

  public func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    #if DEBUG
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    #endif

    // Element inspector — highlight on hover, capture element data on click
    configuration.userContentController.addUserScript(ElementInspectorBridge.userScript)
    ElementInspectorBridge.registerMessageHandler(
      on: configuration.userContentController,
      delegate: context.coordinator
    )

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    webView.allowsBackForwardNavigationGestures = true

    context.coordinator.webView = webView
    loadContent(in: webView)
    return webView
  }

  public func updateNSView(_ webView: WKWebView, context: Context) {
    // Reload if URL or reload token changed
    if context.coordinator.lastLoadedURL != url || context.coordinator.lastReloadToken != reloadToken {
      loadContent(in: webView)
      context.coordinator.lastReloadToken = reloadToken
    }

    // Sync inspect mode with JS without triggering redundant evaluations
    let newInspectState = isInspectModeActive?.wrappedValue ?? false
    if newInspectState != context.coordinator.lastInspectModeState {
      context.coordinator.lastInspectModeState = newInspectState
      if newInspectState {
        ElementInspectorBridge.activate(in: webView)
      } else {
        ElementInspectorBridge.deactivate(in: webView)
      }
    }

    // When the selected element is cleared (nil) while inspect mode is still active,
    // call clearSelection() so hover-following resumes in the JS layer.
    let newSelectedId = selectedElementId
    let oldSelectedId = context.coordinator.lastSelectedElementId
    if oldSelectedId != nil, newSelectedId == nil, newInspectState {
      ElementInspectorBridge.clearSelection(in: webView)
    }
    context.coordinator.lastSelectedElementId = newSelectedId
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  private func loadContent(in webView: WKWebView) {
    if isFileURL {
      let readAccessURL = allowingReadAccessTo ?? url.deletingLastPathComponent()
      webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    } else {
      webView.load(URLRequest(url: url))
    }
  }

  // MARK: - Coordinator

  public class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let parent: InspectableWebView
    var lastLoadedURL: URL?
    var lastReloadToken: UUID?
    var lastInspectModeState: Bool = false
    var lastSelectedElementId: UUID?
    /// Held weakly to avoid retaining the view after dealloc
    weak var webView: WKWebView?

    init(parent: InspectableWebView) {
      self.parent = parent
      self.lastLoadedURL = parent.url
      self.lastReloadToken = parent.reloadToken
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      Task { @MainActor in
        parent.onLoadingChange?(true)
      }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      Task { @MainActor in
        parent.onLoadingChange?(false)
        parent.onURLChange?(webView.url)
        lastLoadedURL = parent.url
      }
      // Re-activate inspector after HMR/page reload if still active
      if parent.isInspectModeActive?.wrappedValue == true {
        ElementInspectorBridge.activate(in: webView)
      }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      Task { @MainActor in
        parent.onLoadingChange?(false)
        parent.onError?(error.localizedDescription)
      }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      Task { @MainActor in
        parent.onLoadingChange?(false)
        parent.onError?(error.localizedDescription)
      }
    }

    // MARK: WKScriptMessageHandler

    public func userContentController(
      _: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard
        message.name == ElementInspectorBridge.messageName,
        let body = message.body as? [String: Any]
      else { return }

      if let messageType = body["type"] as? String, messageType == "selectionRect" {
        let rect = ElementInspectorBridge.parseSelectionRect(body)
        Task { @MainActor in
          parent.onSelectedElementViewportRectChange?(rect)
        }
        return
      }

      Task { @MainActor in
        let element = ElementInspectorBridge.parseElementData(body)
        parent.onElementSelected?(element)
      }
    }
  }
}
