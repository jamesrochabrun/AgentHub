//
//  WebInspectInputOverlay.swift
//  WebInspector
//
//  Floating input overlay that can be bottom-pinned or selection-anchored.
//

import SwiftUI

struct WebInspectInputOverlay: View {
  @Bindable var state: ElementInspectState
  let placement: WebInspectInputPlacement
  let onSubmit: ((ElementInspectorData, String) -> Void)?

  @State private var measuredHeight: CGFloat = Self.defaultHeight

  private static let defaultHeight: CGFloat = 120
  private let contentInset: CGFloat = 12
  private let gap: CGFloat = 12

  var body: some View {
    GeometryReader { geometry in
      switch placement {
      case .bottom:
        bottomOverlay
      case .selectionAnchored:
        anchoredOverlay(in: geometry.size)
      }
    }
  }

  @ViewBuilder
  private var bottomOverlay: some View {
    if let element = state.selectedElement {
      inputView(for: element)
        .padding(contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
  }

  @ViewBuilder
  private func anchoredOverlay(in containerSize: CGSize) -> some View {
    if let element = state.selectedElement {
      inputView(for: element)
        .padding(.horizontal, contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(y: resolvedTopOffset(for: element, containerHeight: containerSize.height))
    }
  }

  private func resolvedTopOffset(for element: ElementInspectorData, containerHeight: CGFloat) -> CGFloat {
    let viewportRect = state.selectedElementViewportRect ?? element.boundingRect
    return WebInspectInputLayoutResolver.resolve(
      containerHeight: containerHeight,
      elementRect: viewportRect,
      inputHeight: measuredHeight,
      topInset: contentInset,
      bottomInset: contentInset,
      gap: gap
    ).topOffset
  }

  private func inputView(for element: ElementInspectorData) -> some View {
    WebInspectInputView(
      element: element,
      onSubmit: { instruction in
        onSubmit?(element, instruction)
        state.deactivate()
      },
      onDismiss: {
        state.dismissInput()
      }
    )
    .background {
      GeometryReader { proxy in
        Color.clear
          .onAppear {
            measuredHeight = max(Self.defaultHeight, proxy.size.height)
          }
          .onChange(of: proxy.size.height) { _, newHeight in
            measuredHeight = max(Self.defaultHeight, newHeight)
          }
      }
    }
  }
}
