//
//  QueuedWebPreviewContextStore.swift
//  AgentHub
//
//  Created by Assistant on 3/23/26.
//

import Canvas
import CoreGraphics
import Foundation

/// Holds queued web-preview updates per session until the next terminal submit consumes them.
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

  mutating func append(_ element: ElementInspectorData, instruction: String?, for sessionID: String) {
    var queue = queue(for: sessionID)
    queue.append(element, instruction: instruction)
    queues[sessionID] = queue
  }

  mutating func appendCrop(
    cropRect: CGRect,
    elements: [ElementInspectorData],
    instruction: String,
    screenshotPath: String?,
    for sessionID: String
  ) {
    var queue = queue(for: sessionID)
    queue.appendCrop(
      cropRect: cropRect,
      elements: elements,
      instruction: instruction,
      screenshotPath: screenshotPath
    )
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

  mutating func transferQueue(from oldSessionID: String, to newSessionID: String) {
    guard oldSessionID != newSessionID,
          let sourceQueue = queues.removeValue(forKey: oldSessionID),
          !sourceQueue.isEmpty else {
      return
    }

    var destinationQueue = queue(for: newSessionID)
    destinationQueue.append(contentsOf: sourceQueue.items)
    queues[newSessionID] = destinationQueue
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
