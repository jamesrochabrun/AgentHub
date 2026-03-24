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
    return ElementInspectorPromptBuilder.buildContextPrompt(elements: elements)
  }
}
