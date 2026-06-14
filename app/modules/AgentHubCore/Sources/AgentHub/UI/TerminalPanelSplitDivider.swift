//
//  TerminalPanelSplitDivider.swift
//  AgentHub
//

import AppKit
import SwiftUI

@MainActor
public struct TerminalPanelSplitDivider: View {
  @GestureState private var dragTranslation: CGFloat = 0
  @State private var isHovering = false
  @State private var cursorIsPushed = false

  private let axis: TerminalPanelKit.SplitAxis
  private let lineOpacity: Double
  private let clampedTranslation: (CGFloat) -> CGFloat
  private let onCommitResize: (CGFloat) -> Void

  public init(
    axis: TerminalPanelKit.SplitAxis,
    lineOpacity: Double,
    clampedTranslation: @escaping (CGFloat) -> CGFloat,
    onCommitResize: @escaping (CGFloat) -> Void
  ) {
    self.axis = axis
    self.lineOpacity = lineOpacity
    self.clampedTranslation = clampedTranslation
    self.onCommitResize = onCommitResize
  }

  public var body: some View {
    hitTarget
      .help("Drag to resize terminal panes")
      .onChange(of: isDragActive) { _, isDragActive in
        updateCursor(isActive: isHovering || isDragActive)
      }
      .onDisappear {
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
    .accessibilityLabel("Resize terminal panes")
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
        x: axis == .horizontal ? clampedTranslation(dragTranslation) : 0,
        y: axis == .vertical ? clampedTranslation(dragTranslation) : 0
      )
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 1)
      .updating($dragTranslation) { value, state, _ in
        state = rawTranslation(from: value)
      }
      .onEnded { value in
        onCommitResize(clampedTranslation(rawTranslation(from: value)))
      }
  }

  private var isDragActive: Bool {
    dragTranslation != 0
  }

  private var isIntentVisible: Bool {
    isHovering || isDragActive
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
