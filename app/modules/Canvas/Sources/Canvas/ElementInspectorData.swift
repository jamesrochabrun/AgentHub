//
//  ElementInspectorData.swift
//  WebInspector
//
//  Data captured when a user clicks an element in inspect mode.
//

import CoreGraphics
import Foundation

/// DOM element data captured by the JS inspector bridge.
public struct ElementInspectorData: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let tagName: String
  /// DOM `id` attribute (may be empty)
  public let elementId: String
  /// `class` attribute string (may be empty)
  public let className: String
  /// Visible text content, truncated to ~100 chars
  public let textContent: String
  /// Outer HTML markup, truncated to ~500 chars
  public let outerHTML: String
  /// Unique CSS selector path, e.g. `.form > button.primary`
  public let cssSelector: String
  /// Key computed styles: color, background-color, font-size, etc.
  public let computedStyles: [String: String]
  /// Element bounding rect in viewport coordinates (`getBoundingClientRect()`).
  public let boundingRect: CGRect

  public init(
    id: UUID = UUID(),
    tagName: String,
    elementId: String,
    className: String,
    textContent: String,
    outerHTML: String,
    cssSelector: String,
    computedStyles: [String: String],
    boundingRect: CGRect
  ) {
    self.id = id
    self.tagName = tagName
    self.elementId = elementId
    self.className = className
    self.textContent = textContent
    self.outerHTML = outerHTML
    self.cssSelector = cssSelector
    self.computedStyles = computedStyles
    self.boundingRect = boundingRect
  }
}
