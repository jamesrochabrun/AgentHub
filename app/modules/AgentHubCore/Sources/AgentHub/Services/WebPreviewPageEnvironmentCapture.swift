//
//  WebPreviewPageEnvironmentCapture.swift
//  AgentHub
//
//  Reads the page's unit-conversion context (viewport size, root/element/
//  parent font sizes) so deterministic edit planning can convert between
//  CSS units exactly as the browser would. Works on both dev-server and
//  static previews — it needs no stylesheet access, only computed styles.
//

import Foundation
import WebKit

enum WebPreviewPageEnvironmentScript {

  static func script(selector: String) -> String? {
    guard let selectorData = try? JSONSerialization.data(withJSONObject: [selector]),
          let selectorArray = String(data: selectorData, encoding: .utf8) else {
      return nil
    }
    let selectorJSON = String(selectorArray.dropFirst().dropLast())

    return """
    (function() {
      var SELECTOR = \(selectorJSON);

      function fontSize(node) {
        try {
          var value = parseFloat(window.getComputedStyle(node).fontSize);
          return isFinite(value) && value > 0 ? value : null;
        } catch (err) { return null; }
      }

      var el = null;
      try { el = document.querySelector(SELECTOR); } catch (err) {}

      var root = fontSize(document.documentElement);
      var element = el ? fontSize(el) : null;
      var parent = el && el.parentElement ? fontSize(el.parentElement) : null;

      return {
        viewportWidth: window.innerWidth || null,
        viewportHeight: window.innerHeight || null,
        rootFontSize: root,
        elementFontSize: element || root,
        parentFontSize: parent || root
      };
    })();
    """
  }
}

@MainActor
protocol WebPreviewPageEnvironmentCapturing {
  func captureEnvironment(
    selector: String,
    in webView: WKWebView
  ) async -> WebPreviewPageEnvironment?
}

@MainActor
struct WebPreviewPageEnvironmentCapture: WebPreviewPageEnvironmentCapturing {
  init() {}

  func captureEnvironment(
    selector: String,
    in webView: WKWebView
  ) async -> WebPreviewPageEnvironment? {
    guard let script = WebPreviewPageEnvironmentScript.script(selector: selector) else {
      return nil
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

    return WebPreviewPageEnvironment.parse(result)
  }
}
