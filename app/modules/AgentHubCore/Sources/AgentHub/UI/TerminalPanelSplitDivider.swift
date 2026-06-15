//
//  TerminalPanelSplitDivider.swift
//  AgentHub
//

import AppKit
import SwiftUI

@MainActor
public struct TerminalPanelSplitDivider: View {
  private let axis: TerminalPanelKit.SplitAxis
  private let lineOpacity: Double
  private let helpText: String
  private let accessibilityLabel: String
  private let clampedTranslation: (CGFloat) -> CGFloat
  private let onCommitResize: (CGFloat) -> Void
  private let onDoubleClick: (() -> Void)?
  private let onDragActivityChanged: (Bool) -> Void

  public init(
    axis: TerminalPanelKit.SplitAxis,
    lineOpacity: Double,
    helpText: String = "Drag to resize terminal panes",
    accessibilityLabel: String = "Resize terminal panes",
    clampedTranslation: @escaping (CGFloat) -> CGFloat,
    onCommitResize: @escaping (CGFloat) -> Void,
    onDoubleClick: (() -> Void)? = nil,
    onDragActivityChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    self.axis = axis
    self.lineOpacity = lineOpacity
    self.helpText = helpText
    self.accessibilityLabel = accessibilityLabel
    self.clampedTranslation = clampedTranslation
    self.onCommitResize = onCommitResize
    self.onDoubleClick = onDoubleClick
    self.onDragActivityChanged = onDragActivityChanged
  }

  public var body: some View {
    TerminalPanelSplitDividerRepresentable(
      axis: axis,
      lineOpacity: lineOpacity,
      helpText: helpText,
      accessibilityLabel: accessibilityLabel,
      clampedTranslation: clampedTranslation,
      onCommitResize: onCommitResize,
      onDoubleClick: onDoubleClick,
      onDragActivityChanged: onDragActivityChanged
    )
    .frame(
      width: axis == .horizontal ? TerminalPanelKit.SplitSizing.dividerDimension : nil,
      height: axis == .vertical ? TerminalPanelKit.SplitSizing.dividerDimension : nil
    )
  }
}

@MainActor
private struct TerminalPanelSplitDividerRepresentable: NSViewRepresentable {
  let axis: TerminalPanelKit.SplitAxis
  let lineOpacity: Double
  let helpText: String
  let accessibilityLabel: String
  let clampedTranslation: (CGFloat) -> CGFloat
  let onCommitResize: (CGFloat) -> Void
  let onDoubleClick: (() -> Void)?
  let onDragActivityChanged: (Bool) -> Void

  func makeNSView(context: Context) -> TerminalPanelSplitDividerView {
    let view = TerminalPanelSplitDividerView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ nsView: TerminalPanelSplitDividerView, context: Context) {
    nsView.configure(
      axis: axis,
      lineOpacity: lineOpacity,
      helpText: helpText,
      accessibilityLabel: accessibilityLabel,
      clampedTranslation: clampedTranslation,
      onCommitResize: onCommitResize,
      onDoubleClick: onDoubleClick,
      onDragActivityChanged: onDragActivityChanged
    )
  }

  static func dismantleNSView(_ nsView: TerminalPanelSplitDividerView, coordinator: ()) {
    nsView.cancelInteraction()
  }
}

@MainActor
private final class TerminalPanelSplitDividerView: NSView {
  private let dividerRuleLayer = CALayer()
  private let railLayer = CALayer()
  private let railStrokeLayer = CAShapeLayer()

  private var axis: TerminalPanelKit.SplitAxis = .horizontal
  private var lineOpacity: Double = 0.25
  private var accessibilityLabelText = "Resize terminal panes"
  private var clampedTranslation: (CGFloat) -> CGFloat = { $0 }
  private var onCommitResize: (CGFloat) -> Void = { _ in }
  private var onDoubleClick: (() -> Void)?
  private var onDragActivityChanged: (Bool) -> Void = { _ in }

  private var trackingArea: NSTrackingArea?
  private var isHovering = false
  private var isDragging = false
  private var dragStartLocation: CGPoint?
  private var displayedTranslation: CGFloat = 0
  private var railTargetLocationInWindow: CGPoint?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupLayers()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupLayers()
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  override var isFlipped: Bool {
    true
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  func configure(
    axis: TerminalPanelKit.SplitAxis,
    lineOpacity: Double,
    helpText: String,
    accessibilityLabel: String,
    clampedTranslation: @escaping (CGFloat) -> CGFloat,
    onCommitResize: @escaping (CGFloat) -> Void,
    onDoubleClick: (() -> Void)?,
    onDragActivityChanged: @escaping (Bool) -> Void
  ) {
    self.axis = axis
    self.lineOpacity = lineOpacity
    self.toolTip = helpText
    self.accessibilityLabelText = accessibilityLabel
    self.clampedTranslation = clampedTranslation
    self.onCommitResize = onCommitResize
    self.onDoubleClick = onDoubleClick
    self.onDragActivityChanged = onDragActivityChanged
    needsLayout = true
    window?.invalidateCursorRects(for: self)
    updateLayerAppearance()
  }

  func cancelInteraction() {
    guard isDragging else { return }
    isDragging = false
    dragStartLocation = nil
    displayedTranslation = 0
    railTargetLocationInWindow = nil
    onDragActivityChanged(false)
    updateLayerAppearance()
    needsLayout = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingArea {
      removeTrackingArea(trackingArea)
    }

    let options: NSTrackingArea.Options = [
      .activeInActiveApp,
      .inVisibleRect,
      .mouseEnteredAndExited
    ]
    let newTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(newTrackingArea)
    trackingArea = newTrackingArea
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: cursor)
  }

  override func mouseEntered(with event: NSEvent) {
    isHovering = true
    updateLayerAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    updateLayerAppearance()
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2, let onDoubleClick {
      cancelInteraction()
      onDoubleClick()
      return
    }

    window?.makeFirstResponder(self)
    isDragging = true
    railTargetLocationInWindow = nil
    dragStartLocation = convert(event.locationInWindow, from: nil)
    displayedTranslation = 0
    onDragActivityChanged(true)
    updateLayerAppearance()
    needsLayout = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragStartLocation else { return }
    let currentLocation = convert(event.locationInWindow, from: nil)
    displayedTranslation = clampedTranslation(rawTranslation(from: dragStartLocation, to: currentLocation))
    railTargetLocationInWindow = nil
    updateLayerFrames()
  }

  override func mouseUp(with event: NSEvent) {
    guard let dragStartLocation else {
      cancelInteraction()
      return
    }

    let currentLocation = convert(event.locationInWindow, from: nil)
    let committedTranslation = clampedTranslation(rawTranslation(from: dragStartLocation, to: currentLocation))
    displayedTranslation = committedTranslation
    railTargetLocationInWindow = railTargetLocationInWindow(for: committedTranslation)
    updateLayerFrames()

    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      onCommitResize(committedTranslation)
    }

    isDragging = false
    self.dragStartLocation = nil
    onDragActivityChanged(false)
    updateLayerAppearance()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    updateDisplayedTranslationFromRailTarget()
    updateLayerFrames()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateLayerAppearance()
  }

  override func isAccessibilityElement() -> Bool {
    true
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    .splitter
  }

  override func accessibilityLabel() -> String? {
    accessibilityLabelText
  }

  private func setupLayers() {
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor

    dividerRuleLayer.actions = disabledLayerActions
    railLayer.actions = disabledLayerActions
    railStrokeLayer.actions = disabledLayerActions

    railLayer.masksToBounds = true
    railLayer.addSublayer(railStrokeLayer)

    layer?.addSublayer(dividerRuleLayer)
    layer?.addSublayer(railLayer)

    updateLayerAppearance()
  }

  private var disabledLayerActions: [String: NSNull] {
    [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "backgroundColor": NSNull(),
      "hidden": NSNull(),
      "opacity": NSNull(),
      "path": NSNull()
    ]
  }

  private var cursor: NSCursor {
    switch axis {
    case .horizontal:
      return .resizeLeftRight
    case .vertical:
      return .resizeUpDown
    }
  }

  private var isIntentVisible: Bool {
    isHovering || isDragging || railTargetLocationInWindow != nil
  }

  private var isStationaryRuleHidden: Bool {
    isDragging || railTargetLocationInWindow != nil
  }

  private func rawTranslation(from start: CGPoint, to current: CGPoint) -> CGFloat {
    switch axis {
    case .horizontal:
      return current.x - start.x
    case .vertical:
      return current.y - start.y
    }
  }

  private func updateLayerAppearance() {
    let ruleOpacity = isIntentVisible ? max(lineOpacity, 0.42) : lineOpacity
    dividerRuleLayer.isHidden = isStationaryRuleHidden
    dividerRuleLayer.backgroundColor = NSColor.labelColor
      .withAlphaComponent(CGFloat(ruleOpacity))
      .cgColor

    railLayer.isHidden = !isIntentVisible
    railLayer.backgroundColor = NSColor.labelColor
      .withAlphaComponent(isDragging ? 0.28 : 0.18)
      .cgColor

    railStrokeLayer.strokeColor = NSColor.white
      .withAlphaComponent(isDragging ? 0.16 : 0.1)
      .cgColor
    railStrokeLayer.fillColor = NSColor.clear.cgColor
  }

  private func updateLayerFrames() {
    let ruleDimension = TerminalPanelKit.SplitSizing.dividerRuleDimension
    let railDimension = TerminalPanelKit.SplitSizing.dividerHoverRailDimension

    switch axis {
    case .horizontal:
      dividerRuleLayer.frame = CGRect(
        x: bounds.midX - ruleDimension / 2,
        y: 0,
        width: ruleDimension,
        height: bounds.height
      )
      railLayer.frame = CGRect(
        x: bounds.midX - railDimension / 2 + displayedTranslation,
        y: 0,
        width: railDimension,
        height: bounds.height
      )
    case .vertical:
      dividerRuleLayer.frame = CGRect(
        x: 0,
        y: bounds.midY - ruleDimension / 2,
        width: bounds.width,
        height: ruleDimension
      )
      railLayer.frame = CGRect(
        x: 0,
        y: bounds.midY - railDimension / 2 + displayedTranslation,
        width: bounds.width,
        height: railDimension
      )
    }

    railLayer.cornerRadius = railDimension / 2
    railStrokeLayer.frame = railLayer.bounds
    railStrokeLayer.path = CGPath(
      roundedRect: railLayer.bounds,
      cornerWidth: railDimension / 2,
      cornerHeight: railDimension / 2,
      transform: nil
    )
  }

  private func railTargetLocationInWindow(for translation: CGFloat) -> CGPoint {
    let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
    switch axis {
    case .horizontal:
      return CGPoint(x: center.x + translation, y: center.y)
    case .vertical:
      return CGPoint(x: center.x, y: center.y + translation)
    }
  }

  private func updateDisplayedTranslationFromRailTarget() {
    guard !isDragging, let railTargetLocationInWindow else { return }

    let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
    let translation: CGFloat
    switch axis {
    case .horizontal:
      translation = railTargetLocationInWindow.x - center.x
    case .vertical:
      translation = railTargetLocationInWindow.y - center.y
    }

    if abs(translation) <= 0.5 {
      displayedTranslation = 0
      self.railTargetLocationInWindow = nil
      updateLayerAppearance()
    } else {
      displayedTranslation = translation
    }
  }
}
