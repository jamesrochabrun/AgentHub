//
//  AppKitGlobalSessionControlPanelPresenter.swift
//  AgentHubGlobalSessionPanel
//

import SwiftUI
import AgentHubCore

#if canImport(AppKit)
import AppKit
import QuartzCore
#endif

#if canImport(AppKit)

// MARK: - GlobalSessionPanelWindow

private final class GlobalSessionPanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  var onToggleDisplayMode: (() -> Void)?

  // ⌘⌥/ toggles the panel's display mode. Command-modified keys are delivered
  // through the key-equivalent path rather than `keyDown`, so handling it here
  // (instead of SwiftUI `.onKeyPress`) makes it reliable whenever the panel is
  // the key window. Command suppresses Option's character remap, so the
  // character reads as "/".
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option],
      event.charactersIgnoringModifiers == "/"
    {
      onToggleDisplayMode?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
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
  private let displayModeToggleRelay = GlobalSessionPanelDisplayModeToggleRelay()
  private var displayMode: GlobalSessionControlPanelDisplayMode = .defaultValue
  private var compactContentHeight: CGFloat?
  private let defaultRegularPanelSize = CGSize(width: 560, height: 420)
  private let minimumRegularPanelSize = CGSize(width: 420, height: 300)
  // The compact panel hugs its content: the SwiftUI view reports its measured
  // height and the window resizes to fit. `defaultCompactPanelSize.height` is
  // only a fallback used until the first measurement arrives; the minimum height
  // is a low safety floor so a measured height is never clamped up.
  private let defaultCompactPanelSize = CGSize(width: 560, height: 154)
  private let minimumCompactPanelSize = CGSize(width: 420, height: 80)
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

    displayMode = GlobalSessionControlPanelDisplayMode.load(from: defaults)

    let content = GlobalSessionControlPanelView(
      claudeViewModel: provider.claudeSessionsViewModel,
      codexViewModel: provider.codexSessionsViewModel,
      selectionRouter: provider.globalSessionSelectionRouter,
      displayModeToggleRelay: displayModeToggleRelay,
      defaults: defaults,
      onClose: { [weak self] in self?.hide() },
      onSelectSession: { [weak self] in self?.activateMainWindow() },
      onDisplayModeChange: { [weak self] mode in
        self?.handleDisplayModeChange(mode)
      },
      onCompactContentHeightChange: { [weak self] height in
        self?.updateCompactContentHeight(height)
      }
    )
    .agentHub(provider)
    .frame(maxWidth: .infinity, maxHeight: .infinity)

    let hostingView = NSHostingView(rootView: content)
    hostingView.sizingOptions = []
    hostingView.frame = NSRect(origin: .zero, size: defaultSize(for: displayMode))
    hostingView.autoresizingMask = [.width, .height]
    // Clip the content layer to the rounded shape so the borderless window's
    // shadow follows the rounded corners instead of the rectangular bounds.
    hostingView.wantsLayer = true
    hostingView.layer?.cornerRadius = panelCornerRadius
    hostingView.layer?.cornerCurve = .continuous
    hostingView.layer?.masksToBounds = true

    let newPanel = GlobalSessionPanelWindow(
      contentRect: initialFrame(for: displayMode),
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
    newPanel.contentMinSize = minimumSize(for: displayMode)
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
    newPanel.onToggleDisplayMode = { [weak self] in
      self?.displayModeToggleRelay.requestToggle()
    }

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
    persist(frame: panel.frame, for: displayMode)
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

  private func handleDisplayModeChange(_ newMode: GlobalSessionControlPanelDisplayMode) {
    guard let panel, displayMode != newMode else { return }

    persist(frame: panel.frame, for: displayMode)

    pendingFramePersistenceTask?.cancel()
    pendingFramePersistenceTask = nil
    let targetPanelFrame = targetFrame(for: newMode, from: panel.frame)
    displayMode = newMode
    panel.contentMinSize = minimumSize(for: newMode)
    applyPanelFrame(panel, to: targetPanelFrame)
  }

  private func handleResize(frame: NSRect) {
    scheduleFramePersistence(frame)
  }

  private func scheduleFramePersistence(_ frame: NSRect) {
    let mode = displayMode
    pendingFramePersistenceTask?.cancel()
    pendingFramePersistenceTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: framePersistenceDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      persist(frame: frame, for: mode)
      pendingFramePersistenceTask = nil
    }
  }

  private func persist(frame: NSRect, for mode: GlobalSessionControlPanelDisplayMode) {
    defaults.set(NSStringFromRect(frame), forKey: frameDefaultsKey(for: mode))
  }

  private func frameDefaultsKey(for mode: GlobalSessionControlPanelDisplayMode) -> String {
    switch mode {
    case .regular:
      return AgentHubDefaults.globalSessionPanelFrame
    case .compact:
      return AgentHubDefaults.globalSessionPanelCompactFrame
    }
  }

  private func defaultSize(for mode: GlobalSessionControlPanelDisplayMode) -> CGSize {
    switch mode {
    case .regular:
      return defaultRegularPanelSize
    case .compact:
      return defaultCompactPanelSize
    }
  }

  private func minimumSize(for mode: GlobalSessionControlPanelDisplayMode) -> CGSize {
    switch mode {
    case .regular:
      return minimumRegularPanelSize
    case .compact:
      return minimumCompactPanelSize
    }
  }

  private func initialFrame(for mode: GlobalSessionControlPanelDisplayMode) -> NSRect {
    switch mode {
    case .regular:
      return restoredOrDefaultRegularFrame()
    case .compact:
      return restoredCompactFrame() ?? resizedFrame(
        from: restoredOrDefaultRegularFrame(),
        height: compactTargetHeight,
        minimumSize: minimumCompactPanelSize
      )
    }
  }

  // A display-mode switch keeps the panel's current width and top-left corner
  // (so a width the user dragged in one mode carries into the other) and only
  // swaps the height. Regular remembers its own height; compact uses its fixed
  // height.
  private func targetFrame(
    for mode: GlobalSessionControlPanelDisplayMode,
    from currentFrame: NSRect
  ) -> NSRect {
    switch mode {
    case .regular:
      let height = max(
        restoredRegularFrame()?.height ?? defaultRegularPanelSize.height,
        minimumRegularPanelSize.height
      )
      return resizedFrame(from: currentFrame, height: height, minimumSize: minimumRegularPanelSize)
    case .compact:
      return resizedFrame(
        from: currentFrame,
        height: compactTargetHeight,
        minimumSize: minimumCompactPanelSize
      )
    }
  }

  private var compactTargetHeight: CGFloat {
    compactContentHeight ?? defaultCompactPanelSize.height
  }

  // The SwiftUI view reports the measured height of the compact layout; resize
  // the window to hug it (keeping width + top edge) so the panel is never taller
  // than its content. Content height is independent of window size, so this
  // can't feed back into a resize loop.
  private func updateCompactContentHeight(_ height: CGFloat) {
    guard height > 20 else { return }
    let rounded = height.rounded()
    guard compactContentHeight != rounded else { return }
    compactContentHeight = rounded

    guard displayMode == .compact, let panel else { return }
    let target = resizedFrame(from: panel.frame, height: rounded, minimumSize: minimumCompactPanelSize)
    guard abs(panel.frame.height - target.height) > 0.5 else { return }
    applyPanelFrame(panel, to: target)
  }

  private func restoredOrDefaultRegularFrame() -> NSRect {
    restoredRegularFrame() ?? defaultRegularFrame()
  }

  private func restoredRegularFrame() -> NSRect? {
    restoredFrame(
      forKey: AgentHubDefaults.globalSessionPanelFrame,
      minimumSize: minimumRegularPanelSize
    )
  }

  private func restoredCompactFrame() -> NSRect? {
    restoredFrame(
      forKey: AgentHubDefaults.globalSessionPanelCompactFrame,
      minimumSize: minimumCompactPanelSize
    )
  }

  private func restoredFrame(forKey key: String, minimumSize: CGSize) -> NSRect? {
    guard let stored = defaults.string(forKey: key) else { return nil }
    let frame = NSRectFromString(stored)
    guard !frame.isEmpty else { return nil }
    return clamped(frame: frame, minimumSize: minimumSize)
  }

  private func defaultRegularFrame() -> NSRect {
    let visible = activeVisibleFrame()
    let origin = CGPoint(
      x: visible.midX - defaultRegularPanelSize.width / 2,
      y: visible.maxY - defaultRegularPanelSize.height - 12
    )
    return clamped(
      frame: NSRect(origin: origin, size: defaultRegularPanelSize),
      minimumSize: minimumRegularPanelSize
    )
  }

  /// Builds a frame that keeps `referenceFrame`'s width and top-left corner but
  /// uses the given height. This is what unifies the panel width across display
  /// modes: a switch reuses the current width (including any width the user
  /// dragged) and only changes the height.
  private func resizedFrame(from referenceFrame: NSRect, height: CGFloat, minimumSize: CGSize) -> NSRect {
    let width = max(referenceFrame.width, minimumSize.width)
    let frame = NSRect(
      x: referenceFrame.minX,
      y: referenceFrame.maxY - height,
      width: width,
      height: height
    )
    return clamped(frame: frame, minimumSize: minimumSize)
  }

  /// Resizes the panel for a display-mode change. The size change is instant:
  /// animating an `NSWindow` frame that hosts a SwiftUI list relayouts the whole
  /// tree every frame and stutters. The SwiftUI content cross-fades instead (see
  /// `GlobalSessionControlPanelView`), so the swap reads as a clean dissolve
  /// rather than a flash or a janky resize.
  private func applyPanelFrame(_ panel: NSPanel, to frame: NSRect) {
    panel.setFrame(frame, display: true)
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.invalidateShadow()
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
