//
//  WebPreviewLiveEditApplier.swift
//  AgentHub
//
//  Applies source-backed design edits to the live Canvas preview.
//

import Canvas
import WebKit

protocol WebPreviewLiveEditApplying {
  @MainActor
  func apply(_ edit: DesignEdit, in webView: WKWebView?)

  @MainActor
  func refreshSelectedElement(in webView: WKWebView?)
}

struct CanvasWebPreviewLiveEditApplier: WebPreviewLiveEditApplying {
  @MainActor
  func apply(_ edit: DesignEdit, in webView: WKWebView?) {
    guard let webView else { return }
    ElementInspectorBridge.applyDesignEdit(edit, in: webView)
  }

  @MainActor
  func refreshSelectedElement(in webView: WKWebView?) {
    guard let webView else { return }
    ElementInspectorBridge.refreshSelectedElement(in: webView)
  }
}
