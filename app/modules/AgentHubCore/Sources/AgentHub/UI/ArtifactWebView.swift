//
//  ArtifactWebView.swift
//  AgentHub
//
//  WKWebView host for a Claude artifact page.
//

import AppKit
import SwiftUI
import WebKit

/// Renders one artifact page.
///
/// Uses the default (persistent) website data store on purpose: artifact pages
/// are private to the signed-in account, so the sign-in has to survive a panel
/// close and an app relaunch. Links that leave claude.ai open in the user's
/// browser rather than turning this panel into a general-purpose browser.
struct ArtifactWebView: NSViewRepresentable {
  let url: URL
  /// Changing this reloads the page — a republish by the agent, or the user
  /// pressing Reload.
  let reloadToken: String
  let onLoadingChange: (Bool) -> Void
  let onFailure: (String) -> Void
  /// The page the web view actually landed on — a signed-out load redirects to
  /// claude.ai's sign-in, which the panel explains rather than leaving bare.
  let onPageChange: (URL?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onLoadingChange: onLoadingChange, onFailure: onFailure, onPageChange: onPageChange)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    // Without a Safari version in the user agent, some app shells serve an
    // "unsupported browser" page to WKWebView.
    configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true

    context.coordinator.load(url, token: reloadToken, in: webView)
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.onLoadingChange = onLoadingChange
    context.coordinator.onFailure = onFailure
    context.coordinator.onPageChange = onPageChange
    context.coordinator.load(url, token: reloadToken, in: webView)
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.stopLoading()
  }

  // MARK: - Coordinator

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onLoadingChange: (Bool) -> Void
    var onFailure: (String) -> Void
    var onPageChange: (URL?) -> Void

    private var loadedToken: String?

    init(
      onLoadingChange: @escaping (Bool) -> Void,
      onFailure: @escaping (String) -> Void,
      onPageChange: @escaping (URL?) -> Void
    ) {
      self.onLoadingChange = onLoadingChange
      self.onFailure = onFailure
      self.onPageChange = onPageChange
    }

    func load(_ url: URL, token: String, in webView: WKWebView) {
      guard loadedToken != token else { return }
      loadedToken = token
      webView.load(URLRequest(url: url))
    }

    /// Loading state is reported from the delegate rather than from `load`,
    /// which runs inside `updateNSView` where touching SwiftUI state is illegal.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      onLoadingChange(true)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      onPageChange(webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      onLoadingChange(false)
      onPageChange(webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
      report(error)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      report(error)
    }

    /// Keeps in-page navigation inside the panel and sends anything that leaves
    /// claude.ai to the browser, so a link in an artifact can't strand the user
    /// in a panel with no address bar.
    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard navigationAction.navigationType == .linkActivated,
            let url = navigationAction.request.url,
            !Self.isClaudeHost(url) else {
        decisionHandler(.allow)
        return
      }

      decisionHandler(.cancel)
      NSWorkspace.shared.open(url)
    }

    /// `target="_blank"` links: WKWebView has no window to open, so hand them
    /// to the browser instead of dropping them.
    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if let url = navigationAction.request.url {
        NSWorkspace.shared.open(url)
      }
      return nil
    }

    private func report(_ error: any Error) {
      onLoadingChange(false)

      // Cancelled loads and policy-interrupted frame loads are the normal
      // result of navigating away or handing a link to the browser.
      let nsError = error as NSError
      let isCancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
      let isPolicyInterrupted = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
      guard !isCancelled, !isPolicyInterrupted else { return }

      onFailure(error.localizedDescription)
    }

    private static func isClaudeHost(_ url: URL) -> Bool {
      guard let host = url.host?.lowercased() else { return false }
      return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }
  }
}
