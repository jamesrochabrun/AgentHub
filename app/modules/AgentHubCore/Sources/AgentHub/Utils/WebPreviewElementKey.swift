//
//  WebPreviewElementKey.swift
//  AgentHub
//
//  Stable identity for an inspected preview element. Element captures carry a
//  fresh UUID every time the page bridge re-reads the DOM, so anything that has
//  to recognize "the same element again" keys off the selector instead.
//

import Canvas
import Foundation

enum WebPreviewElementKey {
  static func make(for element: ElementInspectorData) -> String {
    let selector = element.cssSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    if !selector.isEmpty {
      return "selector:\(selector)"
    }
    if !element.elementId.isEmpty {
      return "id:\(element.elementId)"
    }
    return "tag:\(element.tagName.lowercased())|class:\(element.className)"
  }
}
