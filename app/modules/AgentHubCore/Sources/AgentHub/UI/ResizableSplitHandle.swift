//
//  ResizableSplitHandle.swift
//  AgentHub
//
//  Horizontal drag-resize primitives for split pane layouts.
//

import Foundation
import SwiftUI

enum ResizablePanelSide: Equatable {
  case leading
  case trailing
}

struct ResizeObscuringOverlay: View {
  var body: some View {
    Rectangle()
      .fill(.thinMaterial)
      .overlay {
        Color.black.opacity(0.08)
      }
      .accessibilityHidden(true)
      .allowsHitTesting(false)
  }
}

// MARK: - Drag State Suppression

/// Tracks active split-handle drags so the terminal does not treat the mouse-up
/// that ends a resize as a terminal/tab selection click.
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

// MARK: - ResizablePanelContainer

/// A self-contained split pane whose width state lives entirely inside this view.
/// During a drag, only the divider rail moves. The pane width is committed when
/// the drag ends, matching the smoother terminal panel resize implementation.
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
  let fixedWidth: CGFloat?
  let onResizeInteractionChanged: (Bool) -> Void
  let content: Content

  @State private var width: CGFloat
  @State private var isSuppressingTerminalSelection = false
  @State private var showsResizeObscuringOverlay = false
  @State private var resizeOverlayGeneration = 0

  init(
    side: ResizablePanelSide,
    minWidth: CGFloat,
    maxWidth: CGFloat,
    defaultWidth: CGFloat,
    userDefaultsKey: String,
    fixedWidth: CGFloat? = nil,
    onResizeInteractionChanged: @escaping (Bool) -> Void = { _ in },
    @ViewBuilder content: () -> Content
  ) {
    self.side = side
    self.minWidth = minWidth
    self.maxWidth = maxWidth
    self.defaultWidth = defaultWidth
    self.userDefaultsKey = userDefaultsKey
    self.fixedWidth = fixedWidth
    self.onResizeInteractionChanged = onResizeInteractionChanged
    self.content = content()

    let savedWidth = UserDefaults.standard.double(forKey: userDefaultsKey)
    let initialWidth = savedWidth > 0 ? CGFloat(savedWidth) : defaultWidth
    self._width = State(initialValue: Self.clamped(initialWidth, minWidth: minWidth, maxWidth: maxWidth))
  }

  private var resolvedWidth: CGFloat {
    if let fixedWidth {
      return max(0, fixedWidth)
    }
    return committedWidth
  }

  private var committedWidth: CGFloat {
    return Self.clamped(width, minWidth: minWidth, maxWidth: maxWidth)
  }

  private var isFixedWidth: Bool {
    fixedWidth != nil
  }

  var body: some View {
    HStack(spacing: 0) {
      if side == .trailing {
        handleSlot
          .zIndex(2)
        resizableContent
      } else {
        resizableContent
        handleSlot
          .zIndex(2)
      }
    }
  }

  private var resizableContent: some View {
    content
      .frame(width: resolvedWidth)
      .overlay {
        if showsResizeObscuringOverlay {
          ResizeObscuringOverlay()
        }
      }
  }

  private var handleSlot: some View {
    handle
      .opacity(isFixedWidth ? 0 : 1)
      .frame(width: isFixedWidth ? 0 : TerminalPanelKit.SplitSizing.dividerDimension)
      .allowsHitTesting(!isFixedWidth)
      .accessibilityHidden(isFixedWidth)
  }

  private var handle: some View {
    TerminalPanelSplitDivider(
      axis: .horizontal,
      lineOpacity: 0.25,
      helpText: "Drag to resize panel. Double-click to reset.",
      accessibilityLabel: "Resize panel",
      clampedTranslation: clampedDragTranslation,
      onCommitResize: commitResize,
      onDoubleClick: {
        commitWidth(Self.clamped(defaultWidth, minWidth: minWidth, maxWidth: maxWidth))
      },
      onDragActivityChanged: { isActive in
        setResizeInteractionActive(isActive)
      }
    )
    .onDisappear {
      setResizeInteractionActive(false, immediatelyHideOverlay: true)
    }
  }

  private static func clamped(_ width: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
    max(minWidth, min(maxWidth, width))
  }

  private func clampedDragTranslation(_ dragTranslation: CGFloat) -> CGFloat {
    let proposedWidth = width(from: dragTranslation)
    let clampedWidth = Self.clamped(proposedWidth, minWidth: minWidth, maxWidth: maxWidth)
    return translationDelta(forWidth: clampedWidth)
  }

  private func commitResize(_ dragTranslation: CGFloat) {
    let proposedWidth = width(from: dragTranslation)
    let clampedWidth = Self.clamped(proposedWidth, minWidth: minWidth, maxWidth: maxWidth)
    commitWidth(clampedWidth)
  }

  private func commitWidth(_ newWidth: CGFloat) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      width = newWidth
    }
    UserDefaults.standard.set(Double(newWidth), forKey: userDefaultsKey)
  }

  private func width(from translation: CGFloat) -> CGFloat {
    switch side {
    case .leading:
      return committedWidth + translation
    case .trailing:
      return committedWidth - translation
    }
  }

  private func translationDelta(forWidth newWidth: CGFloat) -> CGFloat {
    switch side {
    case .leading:
      return newWidth - committedWidth
    case .trailing:
      return committedWidth - newWidth
    }
  }

  private func setResizeInteractionActive(_ isActive: Bool, immediatelyHideOverlay: Bool = false) {
    setResizeObscuringOverlay(isActive: isActive, immediatelyHide: immediatelyHideOverlay)
    setTerminalSelectionSuppression(isActive: isActive)
    onResizeInteractionChanged(isActive)
  }

  private func setResizeObscuringOverlay(isActive: Bool, immediatelyHide: Bool = false) {
    resizeOverlayGeneration += 1
    let generation = resizeOverlayGeneration

    if isActive {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        showsResizeObscuringOverlay = true
      }
      return
    }

    if immediatelyHide {
      showsResizeObscuringOverlay = false
      return
    }

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(180))
      guard generation == resizeOverlayGeneration else { return }

      withAnimation(.easeOut(duration: 0.12)) {
        showsResizeObscuringOverlay = false
      }
    }
  }

  private func setTerminalSelectionSuppression(isActive: Bool) {
    guard isActive != isSuppressingTerminalSelection else { return }
    isSuppressingTerminalSelection = isActive

    if isActive {
      ResizeInteractionSuppression.shared.beginResize()
    } else {
      ResizeInteractionSuppression.shared.endResize()
    }
  }
}
