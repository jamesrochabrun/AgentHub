//
//  WebPreviewScrollPosition.swift
//  AgentHub
//
//  Captured browser scroll offsets for preserving preview position across reloads.
//

import Foundation

struct WebPreviewScrollPosition: Equatable {
  let x: Double
  let y: Double

  init?(x: Double, y: Double) {
    guard x.isFinite, y.isFinite else { return nil }
    self.x = x
    self.y = y
  }

  static func fromJavaScriptResult(_ result: Any?) -> WebPreviewScrollPosition? {
    guard let values = result as? [Any],
          values.count == 2,
          let x = numericValue(from: values[0]),
          let y = numericValue(from: values[1]) else {
      return nil
    }

    return WebPreviewScrollPosition(x: x, y: y)
  }

  private static func numericValue(from value: Any) -> Double? {
    if let number = value as? NSNumber {
      return number.doubleValue
    }
    if let double = value as? Double {
      return double
    }
    if let int = value as? Int {
      return Double(int)
    }
    return nil
  }
}
