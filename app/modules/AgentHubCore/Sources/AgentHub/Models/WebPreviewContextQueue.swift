//
//  WebPreviewContextQueue.swift
//  AgentHub
//
//  Created by Assistant on 3/23/26.
//

import Canvas
import Foundation

/// Holds the set of web-preview context selections queued for the next terminal submit.
struct WebPreviewContextQueue: Equatable, Sendable {
  private(set) var elements: [ElementInspectorData] = []

  var isEmpty: Bool {
    elements.isEmpty
  }

  var count: Int {
    elements.count
  }

  mutating func append(_ element: ElementInspectorData) {
    elements.append(element)
  }

  mutating func remove(id: UUID) {
    elements.removeAll { $0.id == id }
  }

  mutating func clear() {
    elements.removeAll()
  }

  func composedContextPrompt() -> String? {
    guard !elements.isEmpty else { return nil }
    if elements.count == 1, let element = elements.first {
      return ElementInspectorPromptBuilder.buildContextPrompt(element: element)
    }

    var lines = [
      "Selected web element context:",
      "",
    ]

    for (index, element) in elements.enumerated() {
      lines.append("### Element \(index + 1)")
      lines.append(contentsOf: Self.elementLines(for: element))
      if index < elements.count - 1 {
        lines.append("")
      }
    }

    return lines.joined(separator: "\n")
  }

  private static let relevantStyles = [
    "background-color", "backgroundColor", "color", "font-size", "fontSize",
    "padding", "border-radius", "borderRadius", "width", "height", "display",
  ]

  // Mirrors Canvas 1.0.2 single-element prompt formatting while supporting queued multi-select locally.
  private static func elementLines(for element: ElementInspectorData) -> [String] {
    var lines = [
      "**Element**: \(element.outerHTML.isEmpty ? element.tagName.lowercased() : element.outerHTML)",
      "**CSS Selector**: \(element.cssSelector)",
    ]

    let presentStyles = relevantStyles.compactMap { key -> String? in
      guard let value = element.computedStyles[key], !value.isEmpty else { return nil }
      return "  \(key): \(value)"
    }
    if !presentStyles.isEmpty {
      lines.append("**Computed Styles**:")
      lines.append(contentsOf: presentStyles)
    }

    return lines
  }
}
