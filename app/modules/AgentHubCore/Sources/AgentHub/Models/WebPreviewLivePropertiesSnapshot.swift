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
  let display: String?
  let position: String?
  let fontFamily: String?
  let fontWeight: String?
  let fontSize: String?
  let lineHeight: String?
  let letterSpacing: String?
  let textAlign: String?
  let textDecoration: String?
  let textTransform: String?
  let textColor: String?
  let backgroundColor: String?
  let opacity: String?
  let boxShadow: String?
  let borderRadius: String?
  let margin: String?
  let padding: String?
  let marginEdges: CSSBoxEdges
  let paddingEdges: CSSBoxEdges
  let flexDirection: String?
  let justifyContent: String?
  let alignItems: String?
  let gap: String?

  init(
    width: String,
    height: String,
    top: String,
    left: String,
    content: String?,
    display: String?,
    position: String?,
    fontFamily: String?,
    fontWeight: String?,
    fontSize: String?,
    lineHeight: String?,
    letterSpacing: String?,
    textAlign: String?,
    textDecoration: String?,
    textTransform: String?,
    textColor: String?,
    backgroundColor: String?,
    opacity: String?,
    boxShadow: String?,
    borderRadius: String?,
    margin: String?,
    padding: String?,
    marginEdges: CSSBoxEdges,
    paddingEdges: CSSBoxEdges,
    flexDirection: String?,
    justifyContent: String?,
    alignItems: String?,
    gap: String?
  ) {
    self.width = width
    self.height = height
    self.top = top
    self.left = left
    self.content = content
    self.display = display
    self.position = position
    self.fontFamily = fontFamily
    self.fontWeight = fontWeight
    self.fontSize = fontSize
    self.lineHeight = lineHeight
    self.letterSpacing = letterSpacing
    self.textAlign = textAlign
    self.textDecoration = textDecoration
    self.textTransform = textTransform
    self.textColor = textColor
    self.backgroundColor = backgroundColor
    self.opacity = opacity
    self.boxShadow = boxShadow
    self.borderRadius = borderRadius
    self.margin = margin
    self.padding = padding
    self.marginEdges = marginEdges
    self.paddingEdges = paddingEdges
    self.flexDirection = flexDirection
    self.justifyContent = justifyContent
    self.alignItems = alignItems
    self.gap = gap
  }

  init(element: ElementInspectorData) {
    let styles = element.styles
    width = Self.pixels(element.boundingRect.width)
    height = Self.pixels(element.boundingRect.height)
    top = Self.pixels(element.boundingRect.minY)
    left = Self.pixels(element.boundingRect.minX)
    content = element.textContent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    display = styles.display
    position = styles.position
    fontFamily = styles.fontFamily
    fontWeight = styles.fontWeight
    fontSize = styles.fontSize
    lineHeight = styles.lineHeight
    letterSpacing = styles.letterSpacing
    textAlign = styles.textAlign
    textDecoration = styles.textDecoration
    textTransform = styles.textTransform
    textColor = styles.textColor
    backgroundColor = styles.backgroundColor
    opacity = styles.opacity
    boxShadow = styles.boxShadow
    borderRadius = styles.borderRadius
    margin = styles.marginShorthand
    padding = styles.paddingShorthand
    marginEdges = styles.margin
    paddingEdges = styles.padding
    flexDirection = styles.flexDirection
    justifyContent = styles.justifyContent
    alignItems = styles.alignItems
    gap = styles.gap
  }

  func value(for property: WebPreviewStyleProperty) -> String? {
    switch property {
    case .textColor:
      textColor
    case .backgroundColor:
      backgroundColor
    case .display:
      display
    case .fontFamily:
      fontFamily
    case .fontSize:
      fontSize
    case .fontWeight:
      fontWeight
    case .lineHeight:
      lineHeight
    case .letterSpacing:
      letterSpacing
    case .textAlign:
      textAlign
    case .margin:
      margin
    case .opacity:
      opacity
    case .padding:
      padding
    case .borderRadius:
      borderRadius
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

  func applyingStyleValue(_ value: String, for property: WebPreviewStyleProperty) -> WebPreviewLivePropertiesSnapshot {
    switch property {
    case .textColor:
      return copy(textColor: value)
    case .backgroundColor:
      return copy(backgroundColor: value)
    case .display:
      return copy(display: value)
    case .fontFamily:
      return copy(fontFamily: value)
    case .fontSize:
      return copy(fontSize: value)
    case .fontWeight:
      return copy(fontWeight: value)
    case .lineHeight:
      return copy(lineHeight: value)
    case .letterSpacing:
      return copy(letterSpacing: value)
    case .textAlign:
      return copy(textAlign: value)
    case .margin:
      return copy(margin: value)
    case .opacity:
      return copy(opacity: value)
    case .padding:
      return copy(padding: value)
    case .borderRadius:
      return copy(borderRadius: value)
    case .width:
      return copy(width: value)
    case .height:
      return copy(height: value)
    case .top:
      return copy(top: value)
    case .left:
      return copy(left: value)
    }
  }

  func updatingContent(_ value: String) -> WebPreviewLivePropertiesSnapshot {
    copy(content: value)
  }

  private func copy(
    width: String? = nil,
    height: String? = nil,
    top: String? = nil,
    left: String? = nil,
    content: String?? = nil,
    display: String?? = nil,
    position: String?? = nil,
    fontFamily: String?? = nil,
    fontWeight: String?? = nil,
    fontSize: String?? = nil,
    lineHeight: String?? = nil,
    letterSpacing: String?? = nil,
    textAlign: String?? = nil,
    textDecoration: String?? = nil,
    textTransform: String?? = nil,
    textColor: String?? = nil,
    backgroundColor: String?? = nil,
    opacity: String?? = nil,
    boxShadow: String?? = nil,
    borderRadius: String?? = nil,
    margin: String?? = nil,
    padding: String?? = nil,
    marginEdges: CSSBoxEdges? = nil,
    paddingEdges: CSSBoxEdges? = nil,
    flexDirection: String?? = nil,
    justifyContent: String?? = nil,
    alignItems: String?? = nil,
    gap: String?? = nil
  ) -> WebPreviewLivePropertiesSnapshot {
    WebPreviewLivePropertiesSnapshot(
      width: width ?? self.width,
      height: height ?? self.height,
      top: top ?? self.top,
      left: left ?? self.left,
      content: content ?? self.content,
      display: display ?? self.display,
      position: position ?? self.position,
      fontFamily: fontFamily ?? self.fontFamily,
      fontWeight: fontWeight ?? self.fontWeight,
      fontSize: fontSize ?? self.fontSize,
      lineHeight: lineHeight ?? self.lineHeight,
      letterSpacing: letterSpacing ?? self.letterSpacing,
      textAlign: textAlign ?? self.textAlign,
      textDecoration: textDecoration ?? self.textDecoration,
      textTransform: textTransform ?? self.textTransform,
      textColor: textColor ?? self.textColor,
      backgroundColor: backgroundColor ?? self.backgroundColor,
      opacity: opacity ?? self.opacity,
      boxShadow: boxShadow ?? self.boxShadow,
      borderRadius: borderRadius ?? self.borderRadius,
      margin: margin ?? self.margin,
      padding: padding ?? self.padding,
      marginEdges: marginEdges ?? self.marginEdges,
      paddingEdges: paddingEdges ?? self.paddingEdges,
      flexDirection: flexDirection ?? self.flexDirection,
      justifyContent: justifyContent ?? self.justifyContent,
      alignItems: alignItems ?? self.alignItems,
      gap: gap ?? self.gap
    )
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
