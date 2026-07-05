//
//  CSSPropertyFamily.swift
//  AgentHub
//
//  Shorthand/longhand interference detection for direct-write insertions.
//  A brand-new declaration is only inserted when no related declaration
//  exists anywhere, so the persisted cascade always matches the live
//  preview the user approved.
//

import Foundation

enum CSSPropertyFamily {

  /// True when inserting `property` as a fresh declaration could interact
  /// with any of `declaredNames`: the property itself, one of its longhands
  /// (`margin` vs `margin-top`), or a shorthand that covers it
  /// (`font-size` vs `font`, `top` vs `inset`).
  static func conflicts(_ property: String, with declaredNames: Set<String>) -> Bool {
    let name = property.lowercased()
    if declaredNames.contains(name) {
      return true
    }
    // Longhands and logical variants of an edited shorthand share its prefix
    // (`margin-top`, `margin-block-start`, `padding-inline`, …).
    if declaredNames.contains(where: { $0.hasPrefix(name + "-") }) {
      return true
    }

    switch name {
    case "background-color":
      return declaredNames.contains("background")
    case "font-size", "font-family", "font-weight", "line-height":
      return declaredNames.contains("font")
    case "border-radius":
      // Corner longhands are not prefixed by the shorthand
      // (`border-top-left-radius`).
      return declaredNames.contains { $0.hasSuffix("-radius") }
    case "top", "left":
      return declaredNames.contains("inset")
        || declaredNames.contains { $0.hasPrefix("inset-") }
    default:
      return false
    }
  }
}
