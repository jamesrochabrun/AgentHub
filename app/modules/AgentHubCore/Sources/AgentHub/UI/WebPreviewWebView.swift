//
//  WebPreviewWebView.swift
//  AgentHub
//
//  Reusable NSViewRepresentable wrapping WKWebView for web content preview.
//

import SwiftUI
import WebKit

// MARK: - WebPreviewWebView

/// Wraps a `WKWebView` for rendering web content, supporting both localhost URLs and local file URLs.
///
/// For file URLs, uses `loadFileURL(_:allowingReadAccessTo:)` so relative assets (CSS, JS, images)
/// resolve correctly within the project directory.
struct WebPreviewWebView: NSViewRepresentable {
  let url: URL
  let isFileURL: Bool
  /// Directory to grant read access for file URLs (typically the project root)
  let allowingReadAccessTo: URL?
  @Binding var isLoading: Bool
  @Binding var currentURL: URL?
  let onError: ((String) -> Void)?
  /// Change this token to force a reload (useful for file:// URLs that don't change path)
  var reloadToken: UUID? = nil

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.allowsMagnification = true
    webView.allowsBackForwardNavigationGestures = true

    loadContent(in: webView)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    // Reload if URL or reload token changed
    if context.coordinator.lastLoadedURL != url || context.coordinator.lastReloadToken != reloadToken {
      loadContent(in: webView)
      context.coordinator.lastReloadToken = reloadToken
    }
  }

  func makeCoordinator() -> Coordinator {
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

  class Coordinator: NSObject, WKNavigationDelegate {
    let parent: WebPreviewWebView
    var lastLoadedURL: URL?
    var lastReloadToken: UUID?

    init(parent: WebPreviewWebView) {
      self.parent = parent
      self.lastLoadedURL = parent.url
      self.lastReloadToken = parent.reloadToken
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      Task { @MainActor in
        parent.isLoading = true
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      Task { @MainActor in
        parent.isLoading = false
        parent.currentURL = webView.url
        lastLoadedURL = parent.url
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      Task { @MainActor in
        parent.isLoading = false
        parent.onError?(error.localizedDescription)
      }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      Task { @MainActor in
        parent.isLoading = false
        parent.onError?(error.localizedDescription)
      }
    }
  }
}
