//
//  QueuedWebPreviewContextStore.swift
//  AgentHub
//
//  Created by Assistant on 3/23/26.
//

import Canvas
import Foundation

/// Holds queued web-preview selections per session until the next terminal submit consumes them.
struct QueuedWebPreviewContextStore: Equatable, Sendable {
  private(set) var queues: [String: WebPreviewContextQueue] = [:]

  func queue(for sessionID: String) -> WebPreviewContextQueue {
    queues[sessionID] ?? WebPreviewContextQueue()
  }

  func count(for sessionID: String) -> Int {
    queues[sessionID]?.count ?? 0
  }

  mutating func append(_ element: ElementInspectorData, for sessionID: String) {
    var queue = queue(for: sessionID)
    queue.append(element)
    queues[sessionID] = queue
  }

  mutating func remove(elementID: UUID, for sessionID: String) {
    guard var queue = queues[sessionID] else { return }
    queue.remove(id: elementID)

    if queue.isEmpty {
      queues.removeValue(forKey: sessionID)
    } else {
      queues[sessionID] = queue
    }
  }

  mutating func clear(for sessionID: String) {
    queues.removeValue(forKey: sessionID)
  }

  func contextPrompt(for sessionID: String) -> String? {
    queue(for: sessionID).composedContextPrompt()
  }

  mutating func consumeContextPrompt(for sessionID: String) -> String? {
    let prompt = contextPrompt(for: sessionID)
    clear(for: sessionID)
    return prompt
  }
}
