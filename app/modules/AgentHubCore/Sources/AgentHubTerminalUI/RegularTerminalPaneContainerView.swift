//
//  RegularTerminalPaneContainerView.swift
//  AgentHub
//

import AppKit

final class RegularTerminalPaneContainerView: NSView {
  private let headerView: NSView
  private let terminalView: NSView
  private let headerHeight: CGFloat

  override var isFlipped: Bool { true }

  init(
    headerView: NSView,
    terminalView: NSView,
    headerHeight: CGFloat,
    initialSize: CGSize
  ) {
    self.headerView = headerView
    self.terminalView = terminalView
    self.headerHeight = headerHeight
    super.init(frame: CGRect(origin: .zero, size: initialSize))
    translatesAutoresizingMaskIntoConstraints = true
    autoresizingMask = []

    headerView.translatesAutoresizingMaskIntoConstraints = true
    headerView.autoresizingMask = []
    terminalView.translatesAutoresizingMaskIntoConstraints = true
    terminalView.autoresizingMask = []

    addSubview(headerView)
    addSubview(terminalView)
    layoutPaneSubviews(in: bounds)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func layout() {
    super.layout()
    layoutPaneSubviews(in: bounds)
  }

  private func layoutPaneSubviews(in rect: CGRect) {
    let resolvedHeaderHeight = min(headerHeight, max(0, rect.height))
    headerView.frame = CGRect(
      x: rect.minX,
      y: rect.minY,
      width: rect.width,
      height: resolvedHeaderHeight
    )
    terminalView.frame = CGRect(
      x: rect.minX,
      y: rect.minY + resolvedHeaderHeight,
      width: rect.width,
      height: max(0, rect.height - resolvedHeaderHeight)
    )
  }
}
