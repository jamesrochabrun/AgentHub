//
//  WebPreviewStyleProvenanceCapture.swift
//  AgentHub
//
//  Evaluates the provenance script in the preview web view and parses the
//  result. Protocol-backed so view-model tests can inject fixtures.
//

import Foundation
import WebKit

@MainActor
protocol WebPreviewStyleProvenanceCapturing {
  func captureProvenance(
    selector: String,
    properties: [String],
    in webView: WKWebView
  ) async -> WebPreviewStyleProvenance?
}

@MainActor
protocol WebPreviewSourceHintCapturing {
  func captureSourceHints(
    selector: String,
    in webView: WKWebView
  ) async -> [WebPreviewElementSourceHint]
}

@MainActor
struct WebPreviewStyleProvenanceCapture: WebPreviewStyleProvenanceCapturing {
  func captureProvenance(
    selector: String,
    properties: [String],
    in webView: WKWebView
  ) async -> WebPreviewStyleProvenance? {
    guard let script = WebPreviewStyleProvenanceScript.script(
      selector: selector,
      properties: properties
    ) else {
      return nil
    }

    let result: Any? = await withCheckedContinuation { continuation in
      webView.evaluateJavaScript(script) { value, error in
        if let error {
          AppLogger.devServer.debug(
            "[WebPreview] Style provenance script failed: \(error.localizedDescription, privacy: .public)"
          )
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: value)
      }
    }

    return WebPreviewStyleProvenance.parse(result)
  }
}

@MainActor
struct WebPreviewSourceHintCapture: WebPreviewSourceHintCapturing {
  func captureSourceHints(
    selector: String,
    in webView: WKWebView
  ) async -> [WebPreviewElementSourceHint] {
    guard let script = WebPreviewSourceHintScript.script(selector: selector) else {
      return []
    }

    let result: Any? = await withCheckedContinuation { continuation in
      webView.evaluateJavaScript(script) { value, error in
        if error != nil {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: value)
      }
    }

    return WebPreviewElementSourceHint.parse(result)
  }
}
