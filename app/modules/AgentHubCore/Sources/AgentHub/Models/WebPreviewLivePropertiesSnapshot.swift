//
//  WebPreviewLivePropertiesSnapshot.swift
//  AgentHub
//
//  Live DOM properties shown in the web preview inspector rail.
//

import Canvas
import Foundation

struct WebPreviewLivePropertiesSnapshot: Equatable, Sendable {
  let width: String
  let height: String
  let top: String
  let left: String
  let content: String?
  let fontFamily: String?
  let fontWeight: String?
  let fontSize: String?
  let lineHeight: String?
  let textColor: String?
  let backgroundColor: String?

  init(
    width: String,
    height: String,
    top: String,
    left: String,
    content: String?,
    fontFamily: String?,
    fontWeight: String?,
    fontSize: String?,
    lineHeight: String?,
    textColor: String?,
    backgroundColor: String?
  ) {
    self.width = width
    self.height = height
    self.top = top
    self.left = left
    self.content = content
    self.fontFamily = fontFamily
    self.fontWeight = fontWeight
    self.fontSize = fontSize
    self.lineHeight = lineHeight
    self.textColor = textColor
    self.backgroundColor = backgroundColor
  }

  init(element: ElementInspectorData) {
    width = Self.pixels(element.boundingRect.width)
    height = Self.pixels(element.boundingRect.height)
    top = Self.pixels(element.boundingRect.minY)
    left = Self.pixels(element.boundingRect.minX)
    content = element.textContent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    fontFamily = Self.styleValue(in: element.computedStyles, keys: ["font-family", "fontFamily"])
    fontWeight = Self.styleValue(in: element.computedStyles, keys: ["font-weight", "fontWeight"])
    fontSize = Self.styleValue(in: element.computedStyles, keys: ["font-size", "fontSize"])
    lineHeight = Self.styleValue(in: element.computedStyles, keys: ["line-height", "lineHeight"])
    textColor = Self.styleValue(in: element.computedStyles, keys: ["color"])
    backgroundColor = Self.styleValue(
      in: element.computedStyles,
      keys: ["background-color", "backgroundColor"]
    )
  }

  func value(for property: WebPreviewStyleProperty) -> String? {
    switch property {
    case .textColor:
      textColor
    case .backgroundColor:
      backgroundColor
    case .fontFamily:
      fontFamily
    case .fontSize:
      fontSize
    case .fontWeight:
      fontWeight
    case .lineHeight:
      lineHeight
    case .padding:
      nil
    case .borderRadius:
      nil
    case .width:
      width
    case .height:
      height
    case .top:
      top
    case .left:
      left
    }
  }

  private static func styleValue(in styles: [String: String], keys: [String]) -> String? {
    for key in keys {
      if let value = styles[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private static func pixels(_ value: CGFloat) -> String {
    let rounded = value.rounded()
    if abs(value - rounded) < 0.01 {
      return "\(Int(rounded))px"
    }
    return "\(String(format: "%.1f", value))px"
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
