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

  /// Adds or replaces the queued Edit Mode changes for one element.
  mutating func upsertDesignEdits(
    _ element: ElementInspectorData,
    instruction: String,
    detail: String?,
    for sessionID: String
  ) {
    var queue = queue(for: sessionID)
    queue.upsertDesignEdits(element, instruction: instruction, detail: detail)
    queues[sessionID] = queue
  }

  /// The id of the queued design-edit chip for `element` in this session.
  func designEditItemID(for element: ElementInspectorData, sessionID: String) -> UUID? {
    queue(for: sessionID).designEditItemID(for: element)
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
    let q = queue(for: sessionID)
    guard let prompt = q.composedContextPrompt() else {
      return nil
    }
    let screenshotPaths = q.screenshotPaths()
    clear(for: sessionID)
    guard !screenshotPaths.isEmpty else { return prompt }
    let pathsPrefix = screenshotPaths
      .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
      .joined(separator: " ")
    return "\(pathsPrefix) \(prompt)"
  }
}
