//
//  WebPreviewContextQueue.swift
//  AgentHub
//
//  Created by Assistant on 3/23/26.
//

import Canvas
import CoreGraphics
import Foundation

/// A web-preview selection queued for the next terminal submit.
struct WebPreviewQueuedUpdate: Identifiable, Equatable, Sendable {
  enum Selection: Equatable, Sendable {
    case element(ElementInspectorData)
    case crop(WebPreviewQueuedCropSelection)
  }

  let id: UUID
  let selection: Selection
  let instruction: String?

  init(
    id: UUID = UUID(),
    selection: Selection,
    instruction: String? = nil
  ) {
    self.id = id
    self.selection = selection
    self.instruction = Self.normalizedInstruction(instruction)
  }

  init(
    element: ElementInspectorData,
    instruction: String? = nil
  ) {
    self.init(id: element.id, selection: .element(element), instruction: instruction)
  }

  init(
    cropRect: CGRect,
    elements: [ElementInspectorData],
    instruction: String,
    screenshotPath: String?
  ) {
    self.init(
      selection: .crop(WebPreviewQueuedCropSelection(
        cropRect: cropRect,
        elements: elements,
        screenshotPath: screenshotPath
      )),
      instruction: instruction
    )
  }

  var kindLabel: String {
    switch selection {
    case .element: return instruction == nil ? "Context" : "Element"
    case .crop: return "Region"
    }
  }

  var iconName: String {
    switch selection {
    case .element: return instruction == nil ? "square.and.arrow.up" : "cursorarrow.rays"
    case .crop: return "crop"
    }
  }

  var summary: String {
    switch selection {
    case .element(let element):
      let tag = element.tagName.isEmpty ? "element" : element.tagName.lowercased()
      guard !element.cssSelector.isEmpty else { return tag }
      return "\(tag) \(element.cssSelector)"
    case .crop(let crop):
      return "Region \(Int(crop.cropRect.width)) x \(Int(crop.cropRect.height)) px"
    }
  }

  var detail: String {
    if let instruction {
      return instruction
    }

    switch selection {
    case .element(let element):
      if !element.outerHTML.isEmpty {
        return element.outerHTML
      }
      if !element.textContent.isEmpty {
        return "\"\(element.textContent)\""
      }
      return element.tagName.lowercased()
    case .crop(let crop):
      return "\(crop.elements.count) captured element\(crop.elements.count == 1 ? "" : "s")"
    }
  }

  var prompt: String {
    switch selection {
    case .element(let element):
      if let instruction {
        return ElementInspectorPromptBuilder.buildPrompt(
          element: element,
          instruction: instruction
        )
      }
      return ElementInspectorPromptBuilder.buildContextPrompt(element: element)

    case .crop(let crop):
      return ElementInspectorPromptBuilder.buildCropPrompt(
        cropRect: crop.cropRect,
        elements: crop.elements,
        instruction: instruction ?? "Use this selected region as additional context.",
        screenshotPath: crop.screenshotPath
      )
    }
  }

  private static func normalizedInstruction(_ instruction: String?) -> String? {
    guard let instruction else { return nil }
    let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct WebPreviewQueuedCropSelection: Equatable, Sendable {
  let cropRect: CGRect
  let elements: [ElementInspectorData]
  let screenshotPath: String?
}

/// Holds the set of web-preview updates queued for the next terminal submit.
struct WebPreviewContextQueue: Equatable, Sendable {
  private(set) var items: [WebPreviewQueuedUpdate] = []

  var isEmpty: Bool {
    items.isEmpty
  }

  var count: Int {
    items.count
  }

  mutating func append(_ element: ElementInspectorData) {
    append(element, instruction: nil)
  }

  mutating func append(_ element: ElementInspectorData, instruction: String?) {
    items.append(WebPreviewQueuedUpdate(element: element, instruction: instruction))
  }

  mutating func appendCrop(
    cropRect: CGRect,
    elements: [ElementInspectorData],
    instruction: String,
    screenshotPath: String?
  ) {
    items.append(WebPreviewQueuedUpdate(
      cropRect: cropRect,
      elements: elements,
      instruction: instruction,
      screenshotPath: screenshotPath
    ))
  }

  mutating func append(contentsOf updates: [WebPreviewQueuedUpdate]) {
    items.append(contentsOf: updates)
  }

  mutating func remove(id: UUID) {
    items.removeAll { $0.id == id }
  }

  mutating func clear() {
    items.removeAll()
  }

  func composedContextPrompt() -> String? {
    guard !items.isEmpty else { return nil }
    if items.count == 1, let item = items.first {
      return item.prompt
    }

    var lines = [
      "Queued web preview updates:",
      "",
      "Please apply these updates together.",
      "",
    ]

    for (index, item) in items.enumerated() {
      lines.append("## Update \(index + 1): \(item.kindLabel)")
      lines.append("")
      lines.append(item.prompt)
      if index < items.count - 1 {
        lines.append("")
      }
    }

    return lines.joined(separator: "\n")
  }
}
