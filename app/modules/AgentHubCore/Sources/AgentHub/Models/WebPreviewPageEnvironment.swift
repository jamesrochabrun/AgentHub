//
//  WebPreviewPageEnvironment.swift
//  AgentHub
//
//  Numeric context captured from the live page so deterministic edit
//  planning can convert between CSS units (rem/em/vw/vh/unitless) exactly
//  the way the browser would.
//

import Foundation

struct WebPreviewPageEnvironment: Equatable, Sendable {
  /// Layout viewport size in CSS pixels.
  var viewportWidth: Double
  var viewportHeight: Double
  /// Computed font-size of the root element, in pixels (basis for `rem`).
  var rootFontSize: Double
  /// Computed font-size of the inspected element, in pixels (basis for `em`
  /// on non-font-size properties and for unitless line-height).
  var elementFontSize: Double
  /// Computed font-size of the inspected element's parent, in pixels (basis
  /// for `em` on the font-size property itself).
  var parentFontSize: Double

  init(
    viewportWidth: Double,
    viewportHeight: Double,
    rootFontSize: Double,
    elementFontSize: Double,
    parentFontSize: Double
  ) {
    self.viewportWidth = viewportWidth
    self.viewportHeight = viewportHeight
    self.rootFontSize = rootFontSize
    self.elementFontSize = elementFontSize
    self.parentFontSize = parentFontSize
  }

  /// Conservative defaults used when the page could not be probed. Chosen to
  /// match browser defaults so px-only stylesheets are unaffected.
  static let fallback = WebPreviewPageEnvironment(
    viewportWidth: 1280,
    viewportHeight: 800,
    rootFontSize: 16,
    elementFontSize: 16,
    parentFontSize: 16
  )

  /// Decodes the dictionary produced by `WebPreviewPageEnvironmentScript`.
  static func parse(_ body: Any?) -> WebPreviewPageEnvironment? {
    guard let dictionary = body as? [String: Any] else { return nil }

    func positive(_ key: String) -> Double? {
      let value: Double?
      if let number = dictionary[key] as? Double {
        value = number
      } else if let number = dictionary[key] as? Int {
        value = Double(number)
      } else if let number = dictionary[key] as? NSNumber {
        value = number.doubleValue
      } else {
        value = nil
      }
      guard let value, value.isFinite, value > 0 else { return nil }
      return value
    }

    guard let viewportWidth = positive("viewportWidth"),
          let viewportHeight = positive("viewportHeight"),
          let rootFontSize = positive("rootFontSize") else {
      return nil
    }

    return WebPreviewPageEnvironment(
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      rootFontSize: rootFontSize,
      elementFontSize: positive("elementFontSize") ?? rootFontSize,
      parentFontSize: positive("parentFontSize") ?? rootFontSize
    )
  }
}
