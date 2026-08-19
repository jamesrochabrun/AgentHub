//
//  StudioDesignEditState.swift
//  AgentHub
//
//  Edit-mode state for the Studio panel: live design edits applied to the
//  scratch page and batched per element until the user sends them to the
//  agent as a re-file request. Studio has no source files to map to, so this
//  is deliberately the small subset of `WebPreviewInspectorViewModel` that
//  matters here: apply live, remember the delta, compose the prompt.
//

import Canvas
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class StudioDesignEditState {
  /// One element's pending changes plus what we know about where it sits.
  struct ElementEdits: Equatable {
    var batch: WebPreviewPendingDesignEditBatch
    var variantName: String?
    var fitToContent = false
    var deleted = false

    var isEmpty: Bool { batch.isEmpty && !fitToContent && !deleted }
    var changeCount: Int { batch.changeCount + (fitToContent ? 1 : 0) + (deleted ? 1 : 0) }
  }

  private(set) var selectedElement: ElementInspectorData?
  private(set) var toolbarValues: DesignToolbarValues?
  /// Keyed by selector; insertion order preserved in `order`.
  private(set) var edits: [String: ElementEdits] = [:]
  private(set) var order: [String] = []

  var pendingChangeCount: Int {
    edits.values.reduce(0) { $0 + $1.changeCount }
  }

  var hasPendingEdits: Bool { pendingChangeCount > 0 }

  var orderedEdits: [ElementEdits] {
    order.compactMap { edits[$0] }.filter { !$0.isEmpty }
  }

  // MARK: Selection

  func select(_ element: ElementInspectorData, variantName: String?) {
    selectedElement = element
    toolbarValues = DesignToolbarValues(element: element)
    if edits[element.cssSelector] == nil {
      edits[element.cssSelector] = ElementEdits(batch: WebPreviewPendingDesignEditBatch(element: element), variantName: variantName)
      order.append(element.cssSelector)
    } else if edits[element.cssSelector]?.variantName == nil {
      edits[element.cssSelector]?.variantName = variantName
    }
  }

  func deselect() {
    selectedElement = nil
    toolbarValues = nil
  }

  /// Refreshes toolbar controls in place from a new DOM capture. Replacing the
  /// values object would reset bound editors mid-keystroke; properties the
  /// user already edited keep their pending value so the page's normalized
  /// read-back (`#fff` → `rgb(255, 255, 255)`) does not fight the controls.
  func refresh(with element: ElementInspectorData) {
    guard let selectedElement, selectedElement.cssSelector == element.cssSelector else { return }
    self.selectedElement = element
    let refreshed = DesignToolbarValues(element: element)
    guard let values = toolbarValues, values.category == refreshed.category else {
      toolbarValues = refreshed
      return
    }
    let edited = Set(edits[element.cssSelector]?.batch.styleChanges.map(\.property) ?? [])
    func adopt(_ property: String, _ apply: () -> Void) {
      if !edited.contains(property) { apply() }
    }
    values.fontFamilyOptions = refreshed.fontFamilyOptions
    adopt("font-family") { values.fontFamily = refreshed.fontFamily }
    adopt("color") { values.color = refreshed.color }
    adopt("background-color") { values.backgroundColor = refreshed.backgroundColor }
    adopt("font-size") { values.fontSize = refreshed.fontSize }
    adopt("font-weight") { values.isBold = refreshed.isBold }
    adopt("font-style") { values.isItalic = refreshed.isItalic }
    adopt("text-align") { values.textAlign = refreshed.textAlign }
    adopt("letter-spacing") { values.letterSpacing = refreshed.letterSpacing }
    adopt("line-height") { values.lineHeight = refreshed.lineHeight }
    adopt("border-radius") { values.borderRadius = refreshed.borderRadius }
    adopt("padding") { values.padding = refreshed.padding }
    adopt("margin") { values.margin = refreshed.margin }
    adopt("object-fit") { values.objectFit = refreshed.objectFit }
    if edits[element.cssSelector]?.batch.textChange == nil {
      values.textContent = refreshed.textContent
    }
  }

  // MARK: Editing

  /// Applies an edit live to the page and records the delta.
  func apply(_ edit: DesignEdit, in webView: WKWebView?) {
    guard let selectedElement, edit.element.cssSelector == selectedElement.cssSelector else { return }
    if let webView {
      ElementInspectorBridge.applyDesignEdit(edit, in: webView)
    }
    let key = selectedElement.cssSelector
    switch edit.action {
    case .updateProperty(let property, let value):
      let old = Self.computedValue(for: property, in: selectedElement)
      edits[key]?.batch.recordStyleChange(property: property.rawValue, oldValue: old, newValue: value)
      Self.mirror(property, value: value, into: toolbarValues)
    case .updateTextContent(let text):
      edits[key]?.batch.recordTextChange(oldText: selectedElement.textContent, newText: text)
      toolbarValues?.textContent = text
    case .fitContent:
      edits[key]?.fitToContent = true
    case .deleteElement:
      edits[key]?.deleted = true
      deselect()
    }
  }

  func clear() {
    edits.removeAll()
    order.removeAll()
    deselect()
  }

  // MARK: Helpers

  static func computedValue(for property: DesignEdit.Property, in element: ElementInspectorData) -> String? {
    let parts = property.rawValue.split(separator: "-")
    let camel = parts.enumerated().map { index, part in
      index == 0 ? String(part) : part.prefix(1).uppercased() + part.dropFirst()
    }.joined()
    let value = element.computedStyles[camel]?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  private static func mirror(_ property: DesignEdit.Property, value: String, into values: DesignToolbarValues?) {
    guard let values else { return }
    switch property {
    case .fontFamily: values.fontFamily = value
    case .color: values.color = value
    case .backgroundColor: values.backgroundColor = value
    case .fontSize: values.fontSize = CSSParser.parsePixelValue(value) ?? values.fontSize
    case .fontWeight: values.isBold = CSSParser.isBoldWeight(value)
    case .fontStyle: values.isItalic = value == "italic"
    case .textAlign: values.textAlign = DesignTextAlignment(rawValue: value) ?? values.textAlign
    case .letterSpacing: values.letterSpacing = value
    case .lineHeight: values.lineHeight = value
    case .borderRadius: values.borderRadius = value
    case .padding: values.padding = value
    case .margin: values.margin = value
    case .objectFit: values.objectFit = value
    }
  }
}
