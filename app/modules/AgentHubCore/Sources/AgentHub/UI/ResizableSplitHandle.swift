//
//  ResizableSplitHandle.swift
//  AgentHub
//
//  Horizontal drag-resize primitives for split pane layouts.
//  Mirrors the vertical ResizableCardContainer pattern.
//

import AppKit
import SwiftUI

enum ResizablePanelSide: Equatable {
  case leading
  case trailing
}

// MARK: - ResizablePanelContainer

/// A self-contained split pane whose width state lives entirely inside this view.
/// Because width changes never propagate to the parent, the parent never re-renders
/// during a drag — eliminating flicker in large parent views like MonitoringPanelView.
///
/// Use `.trailing` when the resizable pane is on the right (right side panel):
/// ```
/// HStack {
///   mainContent.frame(maxWidth: .infinity)
///   ResizablePanelContainer(side: .trailing, ...) { sidePanel }
/// }
/// ```
///
/// Use `.leading` when the resizable pane is on the left (left sidebar):
/// ```
/// HStack {
///   ResizablePanelContainer(side: .leading, ...) { sidebar }
///   mainContent
/// }
/// ```
struct ResizablePanelContainer<Content: View>: View {

  let side: ResizablePanelSide
  let minWidth: CGFloat
  let maxWidth: CGFloat
  let defaultWidth: CGFloat
  let userDefaultsKey: String
  let content: Content

  @State private var width: CGFloat

  init(
    side: ResizablePanelSide,
    minWidth: CGFloat,
    maxWidth: CGFloat,
    defaultWidth: CGFloat,
    userDefaultsKey: String,
    @ViewBuilder content: () -> Content
  ) {
    self.side = side
    self.minWidth = minWidth
    self.maxWidth = maxWidth
    self.defaultWidth = defaultWidth
    self.userDefaultsKey = userDefaultsKey
    self.content = content()

    let savedWidth = UserDefaults.standard.double(forKey: userDefaultsKey)
    let initialWidth = savedWidth > 0 ? CGFloat(savedWidth) : defaultWidth
    self._width = State(initialValue: Self.clamped(initialWidth, minWidth: minWidth, maxWidth: maxWidth))
  }

  private var resolvedWidth: CGFloat {
    Self.clamped(width, minWidth: minWidth, maxWidth: maxWidth)
  }

  var body: some View {
    HStack(spacing: 0) {
      if side == .trailing {
        handle
          .zIndex(2)
        content.frame(width: resolvedWidth)
      } else {
        content.frame(width: resolvedWidth)
        handle
          .zIndex(2)
      }
    }
  }

  private var handle: some View {
    ResizableSplitHandle(
      side: side,
      width: $width,
      minWidth: minWidth,
      maxWidth: maxWidth,
      defaultWidth: defaultWidth,
      onDragEnd: { UserDefaults.standard.set(Double($0), forKey: userDefaultsKey) }
    )
  }

  private static func clamped(_ width: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
    max(minWidth, min(maxWidth, width))
  }
}

// MARK: - ResizableSplitHandle

/// Low-level vertical drag handle. Prefer ``ResizablePanelContainer`` unless you need
/// direct binding access. Back `width` with `@State` in the immediate parent —
/// never bind directly to `@AppStorage`, as that invalidates the entire view tree on
/// every drag point and causes visible flickering.
struct ResizableSplitHandle: View {

  let side: ResizablePanelSide
  @Binding var width: CGFloat
  let minWidth: CGFloat
  let maxWidth: CGFloat
  let defaultWidth: CGFloat
  /// Called once when the drag ends. Use to persist the value.
  var onDragEnd: ((CGFloat) -> Void)? = nil

  @State private var isDragging = false
  @State private var isHovering = false
  @State private var widthAtDragStart: CGFloat = 0
  @State private var previewWidth: CGFloat?

  private var resolvedWidth: CGFloat {
    clamped(width)
  }

  private var previewWidthValue: CGFloat {
    clamped(previewWidth ?? resolvedWidth)
  }

  private var previewOffset: CGFloat {
    switch side {
    case .leading:
      previewWidthValue - resolvedWidth
    case .trailing:
      resolvedWidth - previewWidthValue
    }
  }

  var body: some View {
    ZStack {
      Color.clear
      Rectangle()
        .fill(resizableDividerColor(isDragging: isDragging, isHovering: isHovering))
        .frame(width: resizableDividerThickness(isDragging: isDragging, isHovering: isHovering))
    }
    .frame(width: 8)
    .contentShape(Rectangle())
    .onHover { updateCursor(isHovering: $0) }
    .gesture(dragGesture)
    .overlay(alignment: side == .trailing ? .leading : .trailing) {
      if isDragging {
        previewGuide
          .offset(x: previewOffset)
          .allowsHitTesting(false)
      }
    }
    .onTapGesture(count: 2) {
      let resetWidth = clamped(defaultWidth)
      previewWidth = nil
      withAnimation(.easeInOut(duration: 0.18)) { width = resetWidth }
      onDragEnd?(resetWidth)
    }
    .help("Drag to resize. Double-click to reset.")
    .zIndex(isDragging ? 20 : 10)
    .onDisappear {
      if isDragging { ResizeInteractionSuppression.shared.endResize() }
      isDragging = false
      previewWidth = nil
      updateCursor(isHovering: false)
    }
    .animation(.easeInOut(duration: 0.18), value: isDragging)
  }

  private var previewGuide: some View {
    ZStack(alignment: .top) {
      Rectangle()
        .fill(Color.accentColor.opacity(0.95))
        .frame(width: 3)

      Text("\(Int(previewWidthValue.rounded()))")
        .font(.system(.caption2, design: .monospaced))
        .foregroundColor(.accentColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
          Capsule()
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        )
        .overlay(
          Capsule()
            .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .offset(x: side == .trailing ? -12 : 12, y: 10)
    }
    .frame(maxHeight: .infinity)
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !isDragging {
          isDragging = true
          widthAtDragStart = resolvedWidth
          ResizeInteractionSuppression.shared.beginResize()
        }

        let translatedWidth: CGFloat
        switch side {
        case .leading:
          translatedWidth = widthAtDragStart + value.translation.width
        case .trailing:
          translatedWidth = widthAtDragStart - value.translation.width
        }

        previewWidth = clamped(translatedWidth)
      }
      .onEnded { _ in
        let finalWidth = previewWidthValue
        width = finalWidth
        isDragging = false
        previewWidth = nil
        ResizeInteractionSuppression.shared.endResize()
        onDragEnd?(finalWidth)
      }
  }

  private func updateCursor(isHovering: Bool) {
    guard isHovering != self.isHovering else { return }
    self.isHovering = isHovering
    if isHovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
  }

  private func clamped(_ width: CGFloat) -> CGFloat {
    max(minWidth, min(maxWidth, width))
  }
}
