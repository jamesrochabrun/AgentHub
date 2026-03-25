//
//  WebPreviewSourceResolution.swift
//  AgentHub
//
//  Source-mapping models for the web preview inspector rail.
//

import Foundation

// MARK: - WebPreviewSourceResolutionConfidence

enum WebPreviewSourceResolutionConfidence: Int, Comparable, Sendable {
  case low = 0
  case medium = 1
  case high = 2

  static func < (lhs: WebPreviewSourceResolutionConfidence, rhs: WebPreviewSourceResolutionConfidence) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  var displayName: String {
    switch self {
    case .low: "Low confidence"
    case .medium: "Medium confidence"
    case .high: "High confidence"
    }
  }
}

// MARK: - WebPreviewEditableCapability

enum WebPreviewEditableCapability: Hashable, Sendable {
  case content
  case textColor
  case backgroundColor
  case fontFamily
  case fontSize
  case fontWeight
  case lineHeight
  case padding
  case borderRadius
  case width
  case height
  case top
  case left
  case code
}

// MARK: - WebPreviewStyleProperty

enum WebPreviewStyleProperty: String, CaseIterable, Hashable, Sendable {
  case textColor = "color"
  case backgroundColor = "background-color"
  case fontFamily = "font-family"
  case fontSize = "font-size"
  case fontWeight = "font-weight"
  case lineHeight = "line-height"
  case padding = "padding"
  case borderRadius = "border-radius"
  case width = "width"
  case height = "height"
  case top = "top"
  case left = "left"

  var label: String {
    switch self {
    case .textColor: "Text"
    case .backgroundColor: "Background"
    case .fontFamily: "Font"
    case .fontSize: "Font Size"
    case .fontWeight: "Font Weight"
    case .lineHeight: "Line Height"
    case .padding: "Padding"
    case .borderRadius: "Radius"
    case .width: "Width"
    case .height: "Height"
    case .top: "Top"
    case .left: "Left"
    }
  }

  var capability: WebPreviewEditableCapability {
    switch self {
    case .textColor: .textColor
    case .backgroundColor: .backgroundColor
    case .fontFamily: .fontFamily
    case .fontSize: .fontSize
    case .fontWeight: .fontWeight
    case .lineHeight: .lineHeight
    case .padding: .padding
    case .borderRadius: .borderRadius
    case .width: .width
    case .height: .height
    case .top: .top
    case .left: .left
    }
  }

  var fallbackUnit: String? {
    switch self {
    case .fontSize, .lineHeight, .borderRadius, .width, .height, .top, .left:
      "px"
    default:
      nil
    }
  }

  var supportsColorPicking: Bool {
    switch self {
    case .textColor, .backgroundColor:
      true
    default:
      false
    }
  }
}

// MARK: - WebPreviewSourceMatchRange

struct WebPreviewSourceMatchRange: Equatable, Sendable {
  let location: Int
  let length: Int
}

// MARK: - WebPreviewSourceResolution

struct WebPreviewSourceResolution: Equatable, Sendable {
  let primaryFilePath: String?
  let candidateFilePaths: [String]
  let confidence: WebPreviewSourceResolutionConfidence
  let matchedRanges: [String: [WebPreviewSourceMatchRange]]
  let editableCapabilities: Set<WebPreviewEditableCapability>
  let matchedSelector: String?
  let matchedStylesheetPath: String?
  let allowsInlineStyleEditing: Bool
  let matchedText: String?

  var isLowConfidence: Bool {
    confidence == .low
  }
}
