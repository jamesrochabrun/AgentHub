//
//  TerminalPanelSplitDivider.swift
//  AgentHub
//

import AppKit
import SwiftUI

@MainActor
public struct TerminalPanelSplitDivider: View {
  private struct DragState: Equatable {
    var isActive = false
    var translation: CGFloat = 0
  }

  @GestureState private var dragState = DragState()
  @State private var isHovering = false
  @State private var cursorIsPushed = false

  private let axis: TerminalPanelKit.SplitAxis
  private let lineOpacity: Double
  private let helpText: String
  private let accessibilityLabel: String
  private let movesRailWithDrag: Bool
  private let clampedTranslation: (CGFloat) -> CGFloat
  private let onCommitResize: (CGFloat) -> Void
  private let onDragTranslationChanged: (CGFloat?) -> Void
  private let onDragActivityChanged: (Bool) -> Void

  public init(
    axis: TerminalPanelKit.SplitAxis,
    lineOpacity: Double,
    helpText: String = "Drag to resize terminal panes",
    accessibilityLabel: String = "Resize terminal panes",
    movesRailWithDrag: Bool = true,
    clampedTranslation: @escaping (CGFloat) -> CGFloat,
    onCommitResize: @escaping (CGFloat) -> Void,
    onDragTranslationChanged: @escaping (CGFloat?) -> Void = { _ in },
    onDragActivityChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    self.axis = axis
    self.lineOpacity = lineOpacity
    self.helpText = helpText
    self.accessibilityLabel = accessibilityLabel
    self.movesRailWithDrag = movesRailWithDrag
    self.clampedTranslation = clampedTranslation
    self.onCommitResize = onCommitResize
    self.onDragTranslationChanged = onDragTranslationChanged
    self.onDragActivityChanged = onDragActivityChanged
  }

  public var body: some View {
    hitTarget
      .help(helpText)
      .onChange(of: isDragActive) { _, isDragActive in
        onDragActivityChanged(isDragActive)
        if !isDragActive {
          onDragTranslationChanged(nil)
        }
        updateCursor(isActive: isHovering || isDragActive)
      }
      .onChange(of: dragTranslation) { _, dragTranslation in
        guard isDragActive else { return }
        onDragTranslationChanged(clampedTranslation(dragTranslation))
      }
      .onDisappear {
        onDragTranslationChanged(nil)
        onDragActivityChanged(false)
        updateCursor(isActive: false)
      }
  }

  private var hitTarget: some View {
    ZStack {
      Color.clear
        .contentShape(Rectangle())

      dividerRule

      if isIntentVisible {
        hoverRail
      }
    }
    .frame(
      width: axis == .horizontal ? TerminalPanelKit.SplitSizing.dividerDimension : nil,
      height: axis == .vertical ? TerminalPanelKit.SplitSizing.dividerDimension : nil
    )
    .gesture(dragGesture)
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .onHover { hovering in
      isHovering = hovering
      updateCursor(isActive: hovering || isDragActive)
    }
  }

  private var dividerRule: some View {
    Rectangle()
      .fill(Color.primary.opacity(isIntentVisible ? max(lineOpacity, 0.42) : lineOpacity))
      .frame(
        width: axis == .horizontal ? TerminalPanelKit.SplitSizing.dividerRuleDimension : nil,
        height: axis == .vertical ? TerminalPanelKit.SplitSizing.dividerRuleDimension : nil
      )
      .frame(
        maxWidth: axis == .vertical ? .infinity : nil,
        maxHeight: axis == .horizontal ? .infinity : nil
      )
  }

  private var hoverRail: some View {
    RoundedRectangle(cornerRadius: TerminalPanelKit.SplitSizing.dividerHoverRailDimension / 2)
      .fill(Color.primary.opacity(isDragActive ? 0.28 : 0.18))
      .overlay {
        RoundedRectangle(cornerRadius: TerminalPanelKit.SplitSizing.dividerHoverRailDimension / 2)
          .stroke(Color.white.opacity(isDragActive ? 0.16 : 0.1), lineWidth: 1)
      }
      .frame(
        width: axis == .horizontal ? TerminalPanelKit.SplitSizing.dividerHoverRailDimension : nil,
        height: axis == .vertical ? TerminalPanelKit.SplitSizing.dividerHoverRailDimension : nil
      )
      .frame(
        maxWidth: axis == .vertical ? .infinity : nil,
        maxHeight: axis == .horizontal ? .infinity : nil
      )
      .offset(
        x: axis == .horizontal ? visualDragTranslation : 0,
        y: axis == .vertical ? visualDragTranslation : 0
      )
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 1)
      .updating($dragState) { value, state, _ in
        state = DragState(isActive: true, translation: rawTranslation(from: value))
      }
      .onEnded { value in
        onCommitResize(clampedTranslation(rawTranslation(from: value)))
        onDragTranslationChanged(nil)
      }
  }

  private var dragTranslation: CGFloat {
    dragState.translation
  }

  private var isDragActive: Bool {
    dragState.isActive
  }

  private var isIntentVisible: Bool {
    isHovering || isDragActive
  }

  private var visualDragTranslation: CGFloat {
    movesRailWithDrag ? clampedTranslation(dragTranslation) : 0
  }

  private func rawTranslation(from value: DragGesture.Value) -> CGFloat {
    switch axis {
    case .horizontal:
      return value.translation.width
    case .vertical:
      return value.translation.height
    }
  }

  private func updateCursor(isActive: Bool) {
    if isActive {
      guard !cursorIsPushed else { return }
      resizeCursor.push()
      cursorIsPushed = true
    } else if cursorIsPushed {
      NSCursor.pop()
      cursorIsPushed = false
    }
  }

  private var resizeCursor: NSCursor {
    switch axis {
    case .horizontal:
      return .resizeLeftRight
    case .vertical:
      return .resizeUpDown
    }
  }
}
