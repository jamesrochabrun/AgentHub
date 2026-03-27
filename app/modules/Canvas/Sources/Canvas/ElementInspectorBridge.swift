//
//  ElementInspectorBridge.swift
//  WebInspector
//
//  Encapsulates all WebKit integration for the element inspector:
//  JS script injection, message handler registration, data parsing,
//  and WKWebView control (activate/deactivate/clearSelection).
//

import Foundation
import WebKit

// MARK: - WeakScriptMessageHandler

/// Proxy that prevents `WKUserContentController` from retaining the real handler
/// (which would create a retain cycle through the WKWebView configuration).
public final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var delegate: WKScriptMessageHandler?

  public init(_ delegate: WKScriptMessageHandler) {
    self.delegate = delegate
  }

  public func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    delegate?.userContentController(controller, didReceive: message)
  }
}

// MARK: - ElementInspectorBridge

/// Public API for integrating the element inspector into a WKWebView.
public enum ElementInspectorBridge {

  /// Message handler name used by the JS bridge.
  public static let messageName = "elementInspector"

  /// WKUserScript that installs the inspector overlay, hover highlight,
  /// click capture, and scroll tracking into the page.
  public static var userScript: WKUserScript {
    WKUserScript(
      source: inspectorJS,
      injectionTime: .atDocumentEnd,
      forMainFrameOnly: true
    )
  }

  /// Registers the message handler on the given content controller using a
  /// weak proxy to avoid retain cycles.
  public static func registerMessageHandler(
    on controller: WKUserContentController,
    delegate: WKScriptMessageHandler
  ) {
    controller.add(WeakScriptMessageHandler(delegate), name: messageName)
  }

  /// Parses the dictionary sent from JS `postMessage` into an `ElementInspectorData`.
  public static func parseElementData(_ body: [String: Any]) -> ElementInspectorData {
    let styles = body["computedStyles"] as? [String: String] ?? [:]
    let rect = parseRect(from: body)
    return ElementInspectorData(
      id: UUID(),
      tagName: body["tagName"] as? String ?? "",
      elementId: body["elementId"] as? String ?? "",
      className: body["className"] as? String ?? "",
      textContent: body["textContent"] as? String ?? "",
      outerHTML: body["outerHTML"] as? String ?? "",
      cssSelector: body["cssSelector"] as? String ?? "",
      computedStyles: styles,
      boundingRect: rect
    )
  }

  /// Parses the selected element's latest viewport rect from a rect-only message.
  public static func parseSelectionRect(_ body: [String: Any]) -> CGRect {
    parseRect(from: body)
  }

  /// Activates the inspector overlay in the web view.
  public static func activate(in webView: WKWebView) {
    webView.evaluateJavaScript("window.__elementInspector?.activate()") { _, _ in }
  }

  /// Deactivates the inspector overlay in the web view.
  public static func deactivate(in webView: WKWebView) {
    webView.evaluateJavaScript("window.__elementInspector?.deactivate()") { _, _ in }
  }

  /// Clears the current selection so hover-following resumes.
  public static func clearSelection(in webView: WKWebView) {
    webView.evaluateJavaScript("window.__elementInspector?.clearSelection()") { _, _ in }
  }

  // MARK: - Inspector JavaScript

  // swiftlint:disable:next function_body_length
  private static let inspectorJS: String = """
    (function() {
      var overlay = null;
      var currentTarget = null;
      var selectedElement = null;
      var isActive = false;
      var selectionRectFrame = null;

      function buildCSSSelector(el) {
        var parts = [];
        var node = el;
        var maxDepth = 8;
        while (node && node !== document.body && parts.length < maxDepth) {
          var part = node.tagName.toLowerCase();
          if (node.id) {
            part = '#' + node.id;
            parts.unshift(part);
            break;
          }
          if (node.className && typeof node.className === 'string') {
            var classes = node.className.trim().split(/\\s+/).filter(function(c) { return c.length > 0; });
            if (classes.length > 0) {
              part += '.' + classes.slice(0, 2).join('.');
            }
          }
          var siblings = node.parentElement ? Array.from(node.parentElement.children).filter(function(s) {
            return s.tagName === node.tagName;
          }) : [];
          if (siblings.length > 1) {
            var idx = siblings.indexOf(node) + 1;
            part += ':nth-of-type(' + idx + ')';
          }
          parts.unshift(part);
          node = node.parentElement;
        }
        return parts.join(' > ') || el.tagName.toLowerCase();
      }

      function captureElementData(el) {
        var styles = window.getComputedStyle(el);
        var styleKeys = ['color','backgroundColor','fontSize','fontWeight','padding','margin','display','borderRadius','width','height'];
        var computedStyles = {};
        styleKeys.forEach(function(k) { computedStyles[k] = styles[k] || ''; });
        var text = (el.textContent || '').trim().slice(0, 100);
        var html = (el.outerHTML || '').slice(0, 500);
        return {
          tagName: el.tagName,
          elementId: el.id || '',
          className: el.className || '',
          textContent: text,
          outerHTML: html,
          cssSelector: buildCSSSelector(el),
          computedStyles: computedStyles,
          boundingRect: captureBoundingRect(el)
        };
      }

      function captureBoundingRect(el) {
        var rect = el.getBoundingClientRect();
        return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
      }

      function createOverlay() {
        if (overlay) return;
        overlay = document.createElement('div');
        overlay.style.cssText = [
          'position:fixed',
          'pointer-events:none',
          'z-index:2147483647',
          'box-sizing:border-box',
          'border:2px solid #2563eb',
          'background:rgba(37,99,235,0.08)',
          'border-radius:3px',
          'transition:all 0.08s ease',
          'display:none'
        ].join(';');
        document.body.appendChild(overlay);
      }

      function highlightElement(el) {
        if (!overlay || !el) return;
        var rect = el.getBoundingClientRect();
        overlay.style.left = rect.left + 'px';
        overlay.style.top = rect.top + 'px';
        overlay.style.width = rect.width + 'px';
        overlay.style.height = rect.height + 'px';
        overlay.style.display = 'block';
      }

      function onMouseMove(e) {
        if (!isActive) return;
        if (selectedElement !== null) return;
        var el = e.target;
        if (el === overlay) return;
        currentTarget = el;
        highlightElement(el);
      }

      function onClick(e) {
        if (!isActive) return;
        e.preventDefault();
        e.stopPropagation();
        selectedElement = e.target;
        highlightElement(selectedElement);
        var data = captureElementData(e.target);
        try {
          window.webkit.messageHandlers.elementInspector.postMessage(data);
        } catch(err) {}
      }

      function clearSelection() {
        if (selectionRectFrame !== null) {
          window.cancelAnimationFrame(selectionRectFrame);
          selectionRectFrame = null;
        }
        selectedElement = null;
        if (currentTarget) highlightElement(currentTarget);
      }

      function postSelectedRect() {
        if (!selectedElement) return;
        try {
          window.webkit.messageHandlers.elementInspector.postMessage({
            type: 'selectionRect',
            boundingRect: captureBoundingRect(selectedElement)
          });
        } catch(err) {}
      }

      function scheduleSelectedRectPost() {
        if (!selectedElement || selectionRectFrame !== null) return;
        selectionRectFrame = window.requestAnimationFrame(function() {
          selectionRectFrame = null;
          postSelectedRect();
        });
      }

      function onScroll() {
        if (!selectedElement) return;
        highlightElement(selectedElement);
        scheduleSelectedRectPost();
      }

      function onResize() {
        if (!selectedElement) return;
        highlightElement(selectedElement);
        scheduleSelectedRectPost();
      }

      function activate() {
        if (isActive) return;
        isActive = true;
        createOverlay();
        document.addEventListener('mousemove', onMouseMove, true);
        document.addEventListener('click', onClick, true);
        window.addEventListener('scroll', onScroll, { capture: true, passive: true });
        window.addEventListener('resize', onResize, { passive: true });
        document.body.style.cursor = 'crosshair';
      }

      function deactivate() {
        if (!isActive) return;
        isActive = false;
        document.removeEventListener('mousemove', onMouseMove, true);
        document.removeEventListener('click', onClick, true);
        window.removeEventListener('scroll', onScroll, true);
        window.removeEventListener('resize', onResize);
        document.body.style.cursor = '';
        if (overlay) {
          overlay.style.display = 'none';
        }
        if (selectionRectFrame !== null) {
          window.cancelAnimationFrame(selectionRectFrame);
          selectionRectFrame = null;
        }
        currentTarget = null;
        selectedElement = null;
      }

      window.__elementInspector = { activate: activate, deactivate: deactivate, clearSelection: clearSelection };
    })();
    """

  private static func parseRect(from body: [String: Any]) -> CGRect {
    let rectDict = body["boundingRect"] as? [String: Double] ?? [:]
    return CGRect(
      x: rectDict["x"] ?? 0,
      y: rectDict["y"] ?? 0,
      width: rectDict["width"] ?? 0,
      height: rectDict["height"] ?? 0
    )
  }
}
