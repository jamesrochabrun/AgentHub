//
//  TerminalSplitContainerView.swift
//  AgentHub
//

import AppKit
import Foundation

public final class TerminalSplitContainerView: NSView {
  private var tree: TerminalSplitLayoutTree<UUID>
  private let dividerSize: CGFloat
  private var paneViews: [UUID: NSView]
  private var dividerViews: [NSView] = []

  public override var isFlipped: Bool { true }

  public init(
    tree: TerminalSplitLayoutTree<UUID>,
    dividerSize: CGFloat = 1,
    paneViews: [UUID: NSView]
  ) {
    self.tree = tree
    self.dividerSize = dividerSize
    self.paneViews = paneViews
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    installSubviews()
  }

  public required init?(coder: NSCoder) {
    nil
  }

  public override func layout() {
    super.layout()
    let frames = TerminalSplitFrameCalculator.frames(
      for: tree,
      in: bounds,
      dividerSize: dividerSize
    )
    for (id, view) in paneViews {
      view.frame = frames[id] ?? .zero
    }
    layoutDividers(for: tree, in: bounds, dividerIndex: 0)
  }

  public func update(tree: TerminalSplitLayoutTree<UUID>, paneViews: [UUID: NSView]) {
    for view in self.paneViews.values where view.superview === self {
      view.removeFromSuperview()
    }
    for divider in dividerViews where divider.superview === self {
      divider.removeFromSuperview()
    }
    dividerViews.removeAll()
    self.tree = tree
    self.paneViews = paneViews
    installSubviews()
    needsLayout = true
  }

  private func installSubviews() {
    for id in tree.paneIDs {
      guard let paneView = paneViews[id] else { continue }
      paneView.translatesAutoresizingMaskIntoConstraints = true
      paneView.autoresizingMask = []
      addSubview(paneView)
    }

    let dividerCount = dividerCount(in: tree)
    for _ in 0..<dividerCount {
      let divider = NSView()
      divider.wantsLayer = true
      divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
      addSubview(divider)
      dividerViews.append(divider)
    }
  }

  @discardableResult
  private func layoutDividers(
    for node: TerminalSplitLayoutTree<UUID>,
    in rect: CGRect,
    dividerIndex: Int
  ) -> Int {
    switch node {
    case .pane:
      return dividerIndex
    case .split(let axis, let children):
      guard !children.isEmpty else { return dividerIndex }
      let childFrames = childRects(axis: axis, count: children.count, in: rect)
      var nextDividerIndex = dividerIndex

      for (index, child) in children.enumerated() {
        if index > 0, dividerViews.indices.contains(nextDividerIndex) {
          dividerViews[nextDividerIndex].frame = dividerRect(
            axis: axis,
            before: childFrames[index],
            in: rect
          )
          nextDividerIndex += 1
        }
        nextDividerIndex = layoutDividers(
          for: child,
          in: childFrames[index],
          dividerIndex: nextDividerIndex
        )
      }
      return nextDividerIndex
    }
  }

  private func childRects(axis: TerminalWorkspaceSplitAxis, count: Int, in rect: CGRect) -> [CGRect] {
    guard count > 0 else { return [] }
    let childCount = CGFloat(count)
    switch axis {
    case .vertical:
      let totalDividerWidth = dividerSize * CGFloat(max(count - 1, 0))
      let childWidth = max(0, rect.width - totalDividerWidth) / childCount
      var nextX = rect.minX
      return (0..<count).map { index in
        if index > 0 {
          nextX += dividerSize
        }
        defer { nextX += childWidth }
        return CGRect(x: nextX, y: rect.minY, width: childWidth, height: rect.height)
      }
    case .horizontal:
      let totalDividerHeight = dividerSize * CGFloat(max(count - 1, 0))
      let childHeight = max(0, rect.height - totalDividerHeight) / childCount
      var nextY = rect.minY
      return (0..<count).map { index in
        if index > 0 {
          nextY += dividerSize
        }
        defer { nextY += childHeight }
        return CGRect(x: rect.minX, y: nextY, width: rect.width, height: childHeight)
      }
    }
  }

  private func dividerRect(axis: TerminalWorkspaceSplitAxis, before childRect: CGRect, in rect: CGRect) -> CGRect {
    switch axis {
    case .vertical:
      return CGRect(
        x: childRect.minX - dividerSize,
        y: rect.minY,
        width: dividerSize,
        height: rect.height
      )
    case .horizontal:
      return CGRect(
        x: rect.minX,
        y: childRect.minY - dividerSize,
        width: rect.width,
        height: dividerSize
      )
    }
  }

  private func dividerCount(in node: TerminalSplitLayoutTree<UUID>) -> Int {
    switch node {
    case .pane:
      return 0
    case .split(_, let children):
      return max(children.count - 1, 0) + children.reduce(0) { $0 + dividerCount(in: $1) }
    }
  }
}
