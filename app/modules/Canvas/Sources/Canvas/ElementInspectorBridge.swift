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
      source: makeInspectorScript(),
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

  /// Parses an inspector pane change emitted by the experimental Canvas-hosted pane.
  public static func parsePaneChange(_ body: [String: Any]) -> CanvasInspectorChange? {
    guard let property = body["property"] as? String,
          let value = body["value"] as? String else {
      return nil
    }
    return CanvasInspectorChange(property: property, value: value)
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

  /// Syncs the experimental inspector pane state into the web view.
  public static func updatePaneState(in webView: WKWebView, state: CanvasInspectorPaneState?) {
    let script = "window.__elementInspector?.setPaneState(\(paneStateLiteral(for: state)))"
    webView.evaluateJavaScript(script) { _, _ in }
  }

  // MARK: - Inspector JavaScript

  private static func makeInspectorScript() -> String {
    let tweakpaneModuleBase64 = CanvasResourceLoader.base64EncodedResource(named: "tweakpane.min.js")
    return """
    (function() {
      var tweakpaneModuleBase64 = '\(tweakpaneModuleBase64)';
      var overlay = null;
      var currentTarget = null;
      var selectedElement = null;
      var isActive = false;
      var selectionRectFrame = null;
      var paneState = null;
      var paneShell = null;
      var paneTitle = null;
      var paneSubtitle = null;
      var paneSelector = null;
      var paneStatus = null;
      var paneMessage = null;
      var paneSurface = null;
      var tweakpaneLoading = null;
      var tweakpanePane = null;

      function postMessage(payload) {
        try {
          window.webkit.messageHandlers.elementInspector.postMessage(payload);
        } catch (err) {}
      }

      function decodeBase64(base64) {
        if (!base64) return '';
        try {
          return atob(base64);
        } catch (err) {
          return '';
        }
      }

      function ensureTweakpaneLoaded() {
        if (window.__canvasTweakpaneModule) {
          return Promise.resolve(window.__canvasTweakpaneModule);
        }
        if (tweakpaneLoading) {
          return tweakpaneLoading;
        }

        var source = decodeBase64(tweakpaneModuleBase64);
        if (!source) {
          tweakpaneLoading = Promise.reject(new Error('Missing Tweakpane resource'));
          return tweakpaneLoading;
        }

        var blob = new Blob([source], { type: 'text/javascript' });
        var url = URL.createObjectURL(blob);
        tweakpaneLoading = import(url)
          .then(function(mod) {
            window.__canvasTweakpaneModule = mod;
            return mod;
          })
          .finally(function() {
            URL.revokeObjectURL(url);
          });
        return tweakpaneLoading;
      }

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

      function createPaneShell() {
        if (paneShell) return;

        paneShell = document.createElement('div');
        paneShell.style.cssText = [
          'position:fixed',
          'top:0',
          'right:0',
          'width:320px',
          'max-width:42vw',
          'height:100vh',
          'display:none',
          'flex-direction:column',
          'z-index:2147483646',
          'background:rgba(17,24,39,0.96)',
          'backdrop-filter:blur(18px)',
          'border-left:1px solid rgba(255,255,255,0.08)',
          'box-shadow:-18px 0 42px rgba(0,0,0,0.28)',
          'color:#f9fafb',
          'font-family:-apple-system,BlinkMacSystemFont,\"SF Pro Text\",sans-serif',
          'pointer-events:auto'
        ].join(';');

        paneShell.addEventListener('click', function(e) {
          e.stopPropagation();
        }, true);
        paneShell.addEventListener('mousedown', function(e) {
          e.stopPropagation();
        }, true);

        var header = document.createElement('div');
        header.style.cssText = 'padding:14px 16px 12px;border-bottom:1px solid rgba(255,255,255,0.08);';

        paneTitle = document.createElement('div');
        paneTitle.style.cssText = 'font-size:12px;font-weight:700;letter-spacing:0.04em;text-transform:uppercase;color:#93c5fd;';
        header.appendChild(paneTitle);

        paneSubtitle = document.createElement('div');
        paneSubtitle.style.cssText = 'margin-top:6px;font-size:13px;font-weight:600;line-height:1.4;word-break:break-word;';
        header.appendChild(paneSubtitle);

        paneSelector = document.createElement('div');
        paneSelector.style.cssText = 'margin-top:4px;font-size:11px;line-height:1.4;color:rgba(255,255,255,0.66);word-break:break-all;';
        header.appendChild(paneSelector);

        paneStatus = document.createElement('div');
        paneStatus.style.cssText = 'margin-top:10px;font-size:11px;font-weight:600;color:#fbbf24;';
        header.appendChild(paneStatus);

        paneMessage = document.createElement('div');
        paneMessage.style.cssText = 'display:none;margin-top:10px;padding:10px;border-radius:10px;font-size:11px;line-height:1.45;';
        header.appendChild(paneMessage);

        paneSurface = document.createElement('div');
        paneSurface.style.cssText = 'flex:1 1 auto;overflow:auto;padding:14px;';

        paneShell.appendChild(header);
        paneShell.appendChild(paneSurface);
        document.body.appendChild(paneShell);
      }

      function destroyPane() {
        if (tweakpanePane && typeof tweakpanePane.dispose === 'function') {
          tweakpanePane.dispose();
        }
        tweakpanePane = null;
        if (paneSurface) {
          paneSurface.innerHTML = '';
        }
      }

      function hidePane() {
        destroyPane();
        if (paneShell) {
          paneShell.style.display = 'none';
        }
      }

      function messageColorForTone(tone) {
        switch (tone) {
        case 'warning':
          return {
            text: '#fed7aa',
            background: 'rgba(249,115,22,0.12)',
            border: 'rgba(249,115,22,0.28)'
          };
        case 'error':
          return {
            text: '#fecaca',
            background: 'rgba(239,68,68,0.12)',
            border: 'rgba(239,68,68,0.28)'
          };
        default:
          return {
            text: '#bfdbfe',
            background: 'rgba(59,130,246,0.12)',
            border: 'rgba(59,130,246,0.28)'
          };
        }
      }

      function updatePaneHeader(state) {
        createPaneShell();

        paneTitle.textContent = state.title || 'Inspector';
        paneSubtitle.textContent = state.subtitle || 'No mapped source';
        paneSelector.textContent = state.selector || '';
        paneSelector.style.display = state.selector ? 'block' : 'none';
        paneStatus.textContent = state.statusText || '';

        if (state.messageText) {
          var palette = messageColorForTone(state.messageTone || 'info');
          paneMessage.textContent = state.messageText;
          paneMessage.style.display = 'block';
          paneMessage.style.color = palette.text;
          paneMessage.style.background = palette.background;
          paneMessage.style.border = '1px solid ' + palette.border;
        } else {
          paneMessage.textContent = '';
          paneMessage.style.display = 'none';
        }
      }

      function initialValueForField(field) {
        if (field.kind === 'number') {
          var numericValue = Number(field.value);
          return Number.isFinite(numericValue) ? numericValue : 0;
        }
        return field.value || '';
      }

      function labelForField(field) {
        return field.unit ? field.label + ' (' + field.unit + ')' : field.label;
      }

      function optionsForField(field) {
        var options = {
          label: labelForField(field),
          readonly: !field.isEditable
        };
        if (field.kind === 'color') {
          options.view = 'color';
        }
        return options;
      }

      function serializeFieldValue(field, value) {
        if (field.kind === 'number') {
          return String(value);
        }
        return value == null ? '' : String(value);
      }

      function buildPane(module) {
        if (!paneState || !paneSurface) return;

        var PaneCtor = module && module.Pane ? module.Pane : null;
        if (!PaneCtor) {
          paneStatus.textContent = 'Experimental pane unavailable';
          return;
        }

        destroyPane();
        tweakpanePane = new PaneCtor({ container: paneSurface });

        (paneState.sections || []).forEach(function(section) {
          var folder = tweakpanePane.addFolder({
            title: section.title,
            expanded: true
          });
          (section.fields || []).forEach(function(field) {
            var model = {};
            model[field.identifier] = initialValueForField(field);
            var binding = folder.addBinding(model, field.identifier, optionsForField(field));
            binding.on('change', function(ev) {
              if (!field.isEditable) return;
              postMessage({
                type: 'paneChange',
                property: field.identifier,
                value: serializeFieldValue(field, ev.value)
              });
            });
          });
        });
      }

      function renderPane() {
        if (!paneState || !isActive) {
          hidePane();
          return;
        }

        updatePaneHeader(paneState);
        paneShell.style.display = 'flex';

        ensureTweakpaneLoaded()
          .then(function(module) {
            buildPane(module);
          })
          .catch(function() {
            paneStatus.textContent = 'Experimental pane failed to load';
          });
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
        if (el === overlay || (paneShell && paneShell.contains(el))) return;
        currentTarget = el;
        highlightElement(el);
      }

      function onClick(e) {
        if (!isActive) return;
        if (paneShell && paneShell.contains(e.target)) return;
        e.preventDefault();
        e.stopPropagation();
        selectedElement = e.target;
        highlightElement(selectedElement);
        var data = captureElementData(e.target);
        postMessage(data);
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
        renderPane();
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
        hidePane();
      }

      function setPaneState(nextPaneState) {
        paneState = nextPaneState;
        renderPane();
      }

      window.__elementInspector = {
        activate: activate,
        deactivate: deactivate,
        clearSelection: clearSelection,
        setPaneState: setPaneState
      };
    })();
    """
  }

  private static func parseRect(from body: [String: Any]) -> CGRect {
    let rectDict = body["boundingRect"] as? [String: Double] ?? [:]
    return CGRect(
      x: rectDict["x"] ?? 0,
      y: rectDict["y"] ?? 0,
      width: rectDict["width"] ?? 0,
      height: rectDict["height"] ?? 0
    )
  }

  private static func paneStateLiteral(for state: CanvasInspectorPaneState?) -> String {
    guard let state,
          let data = try? JSONEncoder().encode(state),
          let literal = String(data: data, encoding: .utf8) else {
      return "null"
    }
    return literal
  }
}
