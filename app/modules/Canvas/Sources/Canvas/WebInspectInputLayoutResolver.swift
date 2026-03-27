//
//  WebInspectInputLayoutResolver.swift
//  WebInspector
//
//  Pure layout logic for positioning the inspect input overlay relative to a selected element.
//

import CoreGraphics

enum WebInspectInputVerticalClamp: Equatable {
  case none
  case top
  case bottom
}

struct WebInspectInputResolvedLayout: Equatable {
  let topOffset: CGFloat
  let clamp: WebInspectInputVerticalClamp
}

enum WebInspectInputLayoutResolver {
  static func resolve(
    containerHeight: CGFloat,
    elementRect: CGRect,
    inputHeight: CGFloat,
    topInset: CGFloat,
    bottomInset: CGFloat,
    gap: CGFloat
  ) -> WebInspectInputResolvedLayout {
    let maxTopOffset = max(topInset, containerHeight - bottomInset - inputHeight)
    let preferredTopOffset = elementRect.maxY + gap

    if preferredTopOffset <= topInset {
      return WebInspectInputResolvedLayout(topOffset: topInset, clamp: .top)
    }

    if preferredTopOffset >= maxTopOffset {
      return WebInspectInputResolvedLayout(topOffset: maxTopOffset, clamp: .bottom)
    }

    return WebInspectInputResolvedLayout(topOffset: preferredTopOffset, clamp: .none)
  }
}
