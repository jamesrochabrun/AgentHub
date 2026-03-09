import AppKit
import SwiftUI

struct ResizableCardMetrics {
  let defaultHeight: CGFloat
  let minHeight: CGFloat
}

final class ResizeInteractionSuppression {
  static let shared = ResizeInteractionSuppression()

  private let lock = NSLock()
  private var activeResizeCount = 0
  private var suppressSelectionUntil: TimeInterval = 0

  func beginResize() {
    lock.lock()
    activeResizeCount += 1
    lock.unlock()
  }

  func endResize() {
    lock.lock()
    activeResizeCount = max(0, activeResizeCount - 1)
    suppressSelectionUntil = max(suppressSelectionUntil, ProcessInfo.processInfo.systemUptime + 0.2)
    lock.unlock()
  }

  var shouldSuppressSelection: Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeResizeCount > 0 || ProcessInfo.processInfo.systemUptime < suppressSelectionUntil
  }
}

struct ResizableCardContainer<Content: View>: View {
  @Binding var height: CGFloat
  let metrics: ResizableCardMetrics
  let content: () -> Content

  @State private var isDragging = false
  @State private var isHoveringHandle = false
  @State private var heightAtDragStart: CGFloat = 0
  @State private var previewHeight: CGFloat?

  private let handleHeight: CGFloat = 16

  init(
    height: Binding<CGFloat>,
    metrics: ResizableCardMetrics,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self._height = height
    self.metrics = metrics
    self.content = content
  }

  private var resolvedHeight: CGFloat {
    max(height > 0 ? height : metrics.defaultHeight, metrics.minHeight)
  }

  private var previewHeightValue: CGFloat {
    max(previewHeight ?? resolvedHeight, metrics.minHeight)
  }

  private var previewOffset: CGFloat {
    previewHeightValue - resolvedHeight
  }

  var body: some View {
    VStack(spacing: 0) {
      content()
        .frame(maxWidth: .infinity)
        .frame(height: resolvedHeight, alignment: .top)
        .shadow(
          color: Color.accentColor.opacity(isDragging ? 0.28 : 0),
          radius: isDragging ? 14 : 0,
          y: isDragging ? 4 : 0
        )

      handle
    }
    .overlay(alignment: .bottom) {
      if isDragging {
        previewGuide
          .offset(y: previewOffset)
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: .infinity, alignment: .top)
    .zIndex(isDragging ? 1 : 0)
    .animation(.easeInOut(duration: 0.18), value: isDragging)
    .onDisappear {
      if isDragging {
        ResizeInteractionSuppression.shared.endResize()
      }
      isDragging = false
      previewHeight = nil
      updateHandleCursor(isHovering: false)
    }
  }

  private var handle: some View {
    ZStack {
      Color.clear

      Capsule()
        .fill(resizableDividerColor(isDragging: isDragging, isHovering: isHoveringHandle))
        .frame(height: resizableDividerThickness(isDragging: isDragging, isHovering: isHoveringHandle))
        .padding(.horizontal, 12)
    }
    .frame(height: handleHeight)
    .contentShape(Rectangle())
    .onHover { isHovering in
      updateHandleCursor(isHovering: isHovering)
    }
    .gesture(resizeGesture)
    .onTapGesture(count: 2) {
      height = metrics.defaultHeight
    }
    .help("Drag to resize. Double-click to reset.")
  }

  private var previewGuide: some View {
    ZStack(alignment: .trailing) {
      Capsule()
        .fill(Color.accentColor.opacity(0.95))
        .frame(height: 3)

      Text("\(Int(previewHeightValue.rounded()))")
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
    }
    .padding(.horizontal, 12)
  }

  private var resizeGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !isDragging {
          isDragging = true
          heightAtDragStart = resolvedHeight
          ResizeInteractionSuppression.shared.beginResize()
        }

        previewHeight = max(metrics.minHeight, heightAtDragStart + value.translation.height)
      }
      .onEnded { _ in
        height = previewHeightValue
        isDragging = false
        previewHeight = nil
        ResizeInteractionSuppression.shared.endResize()
      }
  }

  private func updateHandleCursor(isHovering: Bool) {
    guard isHovering != isHoveringHandle else { return }

    isHoveringHandle = isHovering

    if isHovering {
      NSCursor.resizeUpDown.push()
    } else {
      NSCursor.pop()
    }
  }
}

private func resizableDividerColor(isDragging: Bool, isHovering: Bool) -> Color {
  if isHovering {
    return Color.primary.opacity(0.28)
  }
  return Color.primary.opacity(isDragging ? 0.14 : 0.09)
}

private func resizableDividerThickness(isDragging: Bool, isHovering: Bool) -> CGFloat {
  return isHovering || isDragging ? 2 : 1
}
