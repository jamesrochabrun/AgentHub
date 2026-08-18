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

  /// Where the queued instruction came from. Edit Mode changes carry
  /// `.designEdits` so they upsert in place, render as an "Edits" chip, and
  /// pull the convention-preserving preamble into the composed prompt.
  enum Origin: Equatable, Sendable {
    case freeform
    case designEdits
  }

  let id: UUID
  let selection: Selection
  let instruction: String?
  let origin: Origin
  /// Compact chip text shown instead of the full instruction, when set.
  let detailOverride: String?

  init(
    id: UUID = UUID(),
    selection: Selection,
    instruction: String? = nil,
    origin: Origin = .freeform,
    detailOverride: String? = nil
  ) {
    self.id = id
    self.selection = selection
    self.instruction = Self.normalizedInstruction(instruction)
    self.origin = origin
    self.detailOverride = Self.normalizedInstruction(detailOverride)
  }

  init(
    element: ElementInspectorData,
    instruction: String? = nil,
    origin: Origin = .freeform,
    detailOverride: String? = nil
  ) {
    self.init(
      id: element.id,
      selection: .element(element),
      instruction: instruction,
      origin: origin,
      detailOverride: detailOverride
    )
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
    if origin == .designEdits { return "Edits" }
    switch selection {
    case .element: return instruction == nil ? "Context" : "Element"
    case .crop: return "Region"
    }
  }

  var iconName: String {
    if origin == .designEdits { return "slider.horizontal.3" }
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
    if let detailOverride {
      return detailOverride
    }

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
      // Screenshot paths are handled separately at send time so that
      // they appear at the start of the terminal input where Claude
      // Code can detect and attach them as images.
      return ElementInspectorPromptBuilder.buildCropPrompt(
        cropRect: crop.cropRect,
        elements: crop.elements,
        instruction: instruction ?? "Use this selected region as additional context.",
        screenshotPath: nil
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

  /// Adds — or replaces in place — the queued Edit Mode changes for one
  /// element. Edits accumulate per element instead of appending a new chip
  /// for every keystroke or slider step, and the existing chip keeps its id
  /// so the row stays stable and removable while the user keeps editing.
  mutating func upsertDesignEdits(
    _ element: ElementInspectorData,
    instruction: String,
    detail: String? = nil
  ) {
    let key = Self.designEditKey(for: element)
    let existingIndex = items.firstIndex { item in
      item.origin == .designEdits && Self.designEditKey(for: item) == key
    }

    guard let existingIndex else {
      items.append(WebPreviewQueuedUpdate(
        element: element,
        instruction: instruction,
        origin: .designEdits,
        detailOverride: detail
      ))
      return
    }

    items[existingIndex] = WebPreviewQueuedUpdate(
      id: items[existingIndex].id,
      selection: .element(element),
      instruction: instruction,
      origin: .designEdits,
      detailOverride: detail
    )
  }

  /// The id of the queued design-edit chip for `element`, when one exists.
  func designEditItemID(for element: ElementInspectorData) -> UUID? {
    let key = Self.designEditKey(for: element)
    return items.first { item in
      item.origin == .designEdits && Self.designEditKey(for: item) == key
    }?.id
  }

  private static func designEditKey(for element: ElementInspectorData) -> String {
    WebPreviewElementKey.make(for: element)
  }

  private static func designEditKey(for item: WebPreviewQueuedUpdate) -> String? {
    guard case .element(let element) = item.selection else { return nil }
    return designEditKey(for: element)
  }

  mutating func remove(id: UUID) {
    items.removeAll { $0.id == id }
  }

  mutating func clear() {
    items.removeAll()
  }

  func composedContextPrompt() -> String? {
    guard !items.isEmpty else { return nil }
    return prefixedWithDesignEditGuidance(composedBody())
  }

  private func composedBody() -> String {
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

  /// Queued Edit Mode changes describe target values, not code, so the
  /// convention rules lead the prompt — once, no matter how many chips.
  private func prefixedWithDesignEditGuidance(_ body: String) -> String {
    guard items.contains(where: { $0.origin == .designEdits }) else { return body }
    return "\(WebPreviewDesignEditGuidance.preamble)\n\n\(body)"
  }

  /// Returns screenshot file paths from crop items, in queue order.
  /// These are sent at the start of the terminal input so Claude Code
  /// detects and attaches them as images.
  func screenshotPaths() -> [String] {
    items.compactMap { item in
      guard case .crop(let crop) = item.selection else { return nil }
      return crop.screenshotPath
    }
  }
}
