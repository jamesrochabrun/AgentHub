import AgentHubVoice
import SwiftUI

#if canImport(AppKit)
import AppKit

private final class VoiceHUDPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class VoiceHUDWindowDelegate: NSObject, NSWindowDelegate {
  var onFrameChange: ((NSRect) -> Void)?
  var onClose: (() -> Void)?

  func windowDidMove(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    onFrameChange?(window.frame)
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    onFrameChange?(window.frame)
  }

  func windowWillClose(_ notification: Notification) {
    onClose?()
  }
}
#endif

@MainActor
public final class AppKitVoiceHUDPresenter: VoiceHUDPresenting {
  public var isVisible: Bool {
    #if canImport(AppKit)
    panel?.isVisible == true
    #else
    false
    #endif
  }

  private let host: any VoiceHUDHost
  private let engine: RealtimeVoiceEngine
  private let configuration: VoiceHUDConfiguration
  private let defaults: UserDefaults

  #if canImport(AppKit)
  private var panel: VoiceHUDPanel?
  private var windowDelegate: VoiceHUDWindowDelegate?
  private var viewModel: VoiceHUDViewModel?
  private var persistenceTask: Task<Void, Never>?
  private let defaultSize = CGSize(width: 380, height: 480)
  private let minimumSize = CGSize(width: 340, height: 360)
  #endif

  public init(
    host: any VoiceHUDHost,
    engine: RealtimeVoiceEngine,
    configuration: VoiceHUDConfiguration,
    defaults: UserDefaults = .standard
  ) {
    self.host = host
    self.engine = engine
    self.configuration = configuration
    self.defaults = defaults
  }

  public func show() {
    #if canImport(AppKit)
    if let panel {
      panel.orderFrontRegardless()
      panel.makeKey()
      return
    }

    let viewModel = VoiceHUDViewModel(
      host: host,
      engine: engine,
      configuration: configuration,
      defaults: defaults
    )
    let content = VoiceHUDView(
      viewModel: viewModel,
      onClose: { [weak self] in self?.hide() }
    )

    let hostingView = NSHostingView(rootView: content)
    hostingView.sizingOptions = []
    hostingView.frame = NSRect(origin: .zero, size: defaultSize)
    hostingView.autoresizingMask = [.width, .height]
    hostingView.wantsLayer = true
    hostingView.layer?.cornerRadius = 18
    hostingView.layer?.cornerCurve = .continuous
    hostingView.layer?.masksToBounds = true

    let newPanel = VoiceHUDPanel(
      contentRect: initialFrame(),
      styleMask: [
        .borderless,
        .nonactivatingPanel,
        .resizable,
        .fullSizeContentView,
      ],
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
    newPanel.contentMinSize = minimumSize
    newPanel.contentView = hostingView

    let delegate = VoiceHUDWindowDelegate()
    delegate.onFrameChange = { [weak self] frame in
      self?.schedulePersistence(frame)
    }
    delegate.onClose = { [weak self, weak newPanel] in
      newPanel?.delegate = nil
      self?.clearPanel()
    }
    newPanel.delegate = delegate

    panel = newPanel
    windowDelegate = delegate
    self.viewModel = viewModel
    newPanel.orderFrontRegardless()
    newPanel.makeKey()
    viewModel.toggleMicrophone()
    #endif
  }

  public func hide() {
    #if canImport(AppKit)
    guard let panel else { return }
    persist(panel.frame)
    viewModel?.stopAllAudio()
    panel.delegate = nil
    clearPanel()
    panel.close()
    #endif
  }

  #if canImport(AppKit)
  private func initialFrame() -> NSRect {
    if let rawFrame = defaults.string(
      forKey: configuration.settings.hudFrame
    ) {
      let saved = NSRectFromString(rawFrame)
      if saved.width >= minimumSize.width,
         saved.height >= minimumSize.height,
         NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
        return saved
      }
    }
    let visibleFrame = NSScreen.main?.visibleFrame
      ?? NSRect(origin: .zero, size: CGSize(width: 1_440, height: 900))
    return NSRect(
      x: visibleFrame.maxX - defaultSize.width - 24,
      y: visibleFrame.maxY - defaultSize.height - 24,
      width: defaultSize.width,
      height: defaultSize.height
    )
  }

  private func schedulePersistence(_ frame: NSRect) {
    persistenceTask?.cancel()
    persistenceTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      self?.persist(frame)
    }
  }

  private func persist(_ frame: NSRect) {
    defaults.set(
      NSStringFromRect(frame),
      forKey: configuration.settings.hudFrame
    )
  }

  private func clearPanel() {
    persistenceTask?.cancel()
    persistenceTask = nil
    panel = nil
    windowDelegate = nil
    viewModel = nil
  }
  #endif
}
