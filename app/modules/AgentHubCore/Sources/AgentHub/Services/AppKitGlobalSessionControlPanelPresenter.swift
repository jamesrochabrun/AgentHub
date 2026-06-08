//
//  AppKitGlobalSessionControlPanelPresenter.swift
//  AgentHub
//

import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

#if canImport(AppKit)

// MARK: - GlobalSessionPanelWindow

private final class GlobalSessionPanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// MARK: - GlobalSessionPanelWindowDelegate

private final class GlobalSessionPanelWindowDelegate: NSObject, NSWindowDelegate {
  var onMove: ((NSRect) -> Void)?
  var onResize: ((NSRect) -> Void)?
  var onClose: (() -> Void)?

  func windowDidMove(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    onMove?(window.frame)
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    onResize?(window.frame)
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
  }
}

#endif

// MARK: - AppKitGlobalSessionControlPanelPresenter

@MainActor
public final class AppKitGlobalSessionControlPanelPresenter: GlobalSessionControlPanelPresenting {
  public var isVisible: Bool {
    #if canImport(AppKit)
    panel?.isVisible == true
    #else
    false
    #endif
  }

  private weak var provider: AgentHubProvider?
  private let defaults: UserDefaults

  #if canImport(AppKit)
  private var panel: GlobalSessionPanelWindow?
  private var windowDelegate: GlobalSessionPanelWindowDelegate?
  private var pendingFramePersistenceTask: Task<Void, Never>?
  private let defaultCollapsedPanelSize = CGSize(width: 560, height: 420)
  private let minimumCollapsedPanelSize = CGSize(width: 420, height: 300)
  private let framePersistenceDelay: Duration = .milliseconds(200)
  // Must match the corner radius used by GlobalSessionControlPanelView so the
  // AppKit layer mask and the SwiftUI clip line up.
  private let panelCornerRadius: CGFloat = 14
  #endif

  public init(
    provider: AgentHubProvider,
    defaults: UserDefaults = .standard
  ) {
    self.provider = provider
    self.defaults = defaults
  }

  public func show() {
    #if canImport(AppKit)
    guard let provider else { return }

    if let panel {
      NSApp.activate(ignoringOtherApps: true)
      panel.orderFrontRegardless()
      panel.makeKey()
      return
    }

    let content = GlobalSessionControlPanelView(
      claudeViewModel: provider.claudeSessionsViewModel,
      codexViewModel: provider.codexSessionsViewModel,
      selectionRouter: provider.globalSessionSelectionRouter,
      onClose: { [weak self] in self?.hide() },
      onSelectSession: { [weak self] in self?.activateMainWindow() }
    )
    .agentHub(provider)
    .frame(maxWidth: .infinity, maxHeight: .infinity)

    let hostingView = NSHostingView(rootView: content)
    hostingView.sizingOptions = []
    hostingView.frame = NSRect(origin: .zero, size: defaultCollapsedPanelSize)
    hostingView.autoresizingMask = [.width, .height]
    // Clip the content layer to the rounded shape so the borderless window's
    // shadow follows the rounded corners instead of the rectangular bounds.
    hostingView.wantsLayer = true
    hostingView.layer?.cornerRadius = panelCornerRadius
    hostingView.layer?.cornerCurve = .continuous
    hostingView.layer?.masksToBounds = true

    let newPanel = GlobalSessionPanelWindow(
      contentRect: restoredOrDefaultFrame(
        defaultSize: defaultCollapsedPanelSize,
        minimumSize: minimumCollapsedPanelSize
      ),
      styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    newPanel.isReleasedWhenClosed = false
    newPanel.hidesOnDeactivate = false
    newPanel.isMovableByWindowBackground = true
    newPanel.level = .statusBar
    newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    newPanel.backgroundColor = .clear
    newPanel.isOpaque = false
    newPanel.hasShadow = true
    newPanel.contentMinSize = minimumCollapsedPanelSize
    newPanel.contentView = hostingView

    let delegate = GlobalSessionPanelWindowDelegate()
    delegate.onMove = { [weak self] frame in
      self?.scheduleFramePersistence(frame)
    }
    delegate.onResize = { [weak self] frame in
      self?.handleResize(frame: frame)
    }
    delegate.onClose = { [weak self, weak newPanel] in
      newPanel?.delegate = nil
      self?.pendingFramePersistenceTask?.cancel()
      self?.pendingFramePersistenceTask = nil
      self?.panel = nil
      self?.windowDelegate = nil
    }
    newPanel.delegate = delegate

    panel = newPanel
    windowDelegate = delegate
    NSApp.activate(ignoringOtherApps: true)
    newPanel.orderFrontRegardless()
    newPanel.makeKey()
    newPanel.invalidateShadow()
    #endif
  }

  public func hide() {
    #if canImport(AppKit)
    guard let panel else { return }
    pendingFramePersistenceTask?.cancel()
    pendingFramePersistenceTask = nil
    persist(frame: panel.frame)
    panel.delegate = nil
    self.panel = nil
    windowDelegate = nil
    panel.close()
    #endif
  }

  #if canImport(AppKit)
  private func activateMainWindow() {
    NSApp.activate(ignoringOtherApps: true)

    let mainWindow = NSApp.windows.first { window in
      window !== panel
        && window.isVisible
        && !(window is NSPanel)
    } ?? NSApp.windows.first { window in
      window !== panel
        && !(window is NSPanel)
    }
    mainWindow?.makeKeyAndOrderFront(nil)
  }

  private func handleResize(frame: NSRect) {
    scheduleFramePersistence(frame)
  }

  private func scheduleFramePersistence(_ frame: NSRect) {
    pendingFramePersistenceTask?.cancel()
    pendingFramePersistenceTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: framePersistenceDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      persist(frame: frame)
      pendingFramePersistenceTask = nil
    }
  }

  private func persist(frame: NSRect) {
    defaults.set(NSStringFromRect(frame), forKey: AgentHubDefaults.globalSessionPanelFrame)
  }

  private func restoredOrDefaultFrame(defaultSize: CGSize, minimumSize: CGSize) -> NSRect {
    if let stored = defaults.string(forKey: AgentHubDefaults.globalSessionPanelFrame) {
      let frame = NSRectFromString(stored)
      if !frame.isEmpty {
        return clamped(frame: frame, minimumSize: minimumSize)
      }
    }

    let visible = activeVisibleFrame()
    let origin = CGPoint(
      x: visible.midX - defaultSize.width / 2,
      y: visible.maxY - defaultSize.height - 12
    )
    return clamped(frame: NSRect(origin: origin, size: defaultSize), minimumSize: minimumSize)
  }

  private func clamped(frame: NSRect, minimumSize: CGSize) -> NSRect {
    let visible = NSScreen.screens
      .first { $0.visibleFrame.intersects(frame) }?
      .visibleFrame ?? activeVisibleFrame()
    let width = min(max(frame.width, minimumSize.width), visible.width)
    let height = min(max(frame.height, minimumSize.height), visible.height)
    let x = min(max(frame.origin.x, visible.minX), visible.maxX - width)
    let y = min(max(frame.origin.y, visible.minY), visible.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  private func activeVisibleFrame() -> NSRect {
    let mouseLocation = NSEvent.mouseLocation
    if let screen = NSScreen.screens.first(where: { screen in
      NSMouseInRect(mouseLocation, screen.frame, false)
    }) {
      return screen.visibleFrame
    }
    return NSScreen.main?.visibleFrame
      ?? NSScreen.screens.first?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
  }
  #endif
}
