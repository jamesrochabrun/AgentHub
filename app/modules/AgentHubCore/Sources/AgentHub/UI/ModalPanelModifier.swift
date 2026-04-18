//
//  ModalPanelModifier.swift
//  AgentHub
//
//  Presents SwiftUI content in native macOS NSPanel windows.
//  Two styles: `.modalPanel()` for resizable windows (Diff, File Explorer)
//  and `.floatingPanel()` for borderless popups (Quick File Picker).
//

import AppKit
import SwiftUI

// MARK: - Environment Forwarding

/// Environments captured from the parent view tree and injected into an `NSHostingView`
/// so detached AppKit-hosted content still respects the active theme and provider.
/// Reading these in the modifier's `body(content:)` ensures the modifier republishes
/// when either value changes, which re-hosts the popped-out window.
private struct HostedPanelEnvironment {
  var runtimeTheme: RuntimeTheme?
  var agentHub: AgentHubProvider?
}

private extension View {
  func forwardingHostedEnvironment(_ env: HostedPanelEnvironment) -> some View {
    self
      .environment(\.runtimeTheme, env.runtimeTheme)
      .environment(\.agentHub, env.agentHub)
  }
}

// MARK: - Panel Window Delegate

private final class PanelWindowDelegate: NSObject, NSWindowDelegate {
  var onClose: (() -> Void)?
  var onResignKey: (() -> Void)?

  func windowWillClose(_ notification: Notification) {
    onClose?()
  }

  func windowDidResignKey(_ notification: Notification) {
    onResignKey?()
  }
}

// MARK: - Floating Panel (borderless, accepts key for keyboard input)

private final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// MARK: - Modal Panel Modifier (resizable window)

private struct ModalPanelModifier<Item: Identifiable, PanelContent: View>: ViewModifier {
  @Binding var item: Item?
  let title: String
  let autosaveName: String
  let defaultSize: CGSize
  let minSize: CGSize
  let panelContent: (Item) -> PanelContent

  @State private var panel: NSPanel?
  @State private var windowDelegate: PanelWindowDelegate?

  @Environment(\.runtimeTheme) private var runtimeTheme
  @Environment(\.agentHub) private var agentHub

  func body(content: Content) -> some View {
    content
      .onChange(of: item.map { AnyHashable($0.id) }) { _, newValue in
        if newValue != nil, let currentItem = item {
          presentPanel(for: currentItem)
        } else {
          dismissPanel()
        }
      }
      .onDisappear {
        dismissPanel()
      }
  }

  private func presentPanel(for currentItem: Item) {
    dismissPanel()

    let forwarded = HostedPanelEnvironment(
      runtimeTheme: runtimeTheme,
      agentHub: agentHub
    )
    let view = panelContent(currentItem).forwardingHostedEnvironment(forwarded)
    let hostingView = NSHostingView(rootView: view)

    let newPanel = NSPanel(
      contentRect: NSRect(origin: .zero, size: defaultSize),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    newPanel.title = title
    newPanel.minSize = minSize
    newPanel.isReleasedWhenClosed = false
    newPanel.hidesOnDeactivate = false
    newPanel.contentView = hostingView

    let delegate = PanelWindowDelegate()
    delegate.onClose = { [weak newPanel] in
      newPanel?.delegate = nil
      item = nil
    }
    newPanel.delegate = delegate

    // Restore saved frame or center on screen
    if !newPanel.setFrameUsingName(autosaveName) {
      newPanel.center()
    }
    newPanel.setFrameAutosaveName(autosaveName)
    newPanel.makeKeyAndOrderFront(nil)

    self.panel = newPanel
    self.windowDelegate = delegate
  }

  private func dismissPanel() {
    guard let existingPanel = panel else { return }
    existingPanel.delegate = nil
    panel = nil
    windowDelegate = nil
    existingPanel.close()
  }
}

// MARK: - Floating Panel Modifier (borderless, centered, no resize/move)

private struct FloatingPanelModifier<PanelContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let defaultSize: CGSize
  let panelContent: () -> PanelContent

  @State private var panel: NSPanel?
  @State private var windowDelegate: PanelWindowDelegate?

  func body(content: Content) -> some View {
    content
      .onChange(of: isPresented) { _, show in
        if show {
          presentPanel()
        } else {
          dismissPanel()
        }
      }
      .onDisappear {
        dismissPanel()
      }
  }

  private func presentPanel() {
    dismissPanel()

    let view = panelContent()
    let hostingView = NSHostingView(rootView: view)

    let newPanel = KeyablePanel(
      contentRect: NSRect(origin: .zero, size: defaultSize),
      styleMask: [.borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    newPanel.isReleasedWhenClosed = false
    newPanel.hidesOnDeactivate = false
    newPanel.isMovableByWindowBackground = false
    newPanel.level = .floating
    newPanel.backgroundColor = .clear
    newPanel.isOpaque = false
    newPanel.hasShadow = false
    newPanel.contentView = hostingView

    let delegate = PanelWindowDelegate()
    delegate.onClose = { [weak newPanel] in
      newPanel?.delegate = nil
      isPresented = false
    }
    delegate.onResignKey = { [weak newPanel] in
      newPanel?.delegate = nil
      isPresented = false
      newPanel?.close()
    }
    newPanel.delegate = delegate

    newPanel.center()
    newPanel.makeKeyAndOrderFront(nil)

    self.panel = newPanel
    self.windowDelegate = delegate
  }

  private func dismissPanel() {
    guard let existingPanel = panel else { return }
    existingPanel.delegate = nil
    panel = nil
    windowDelegate = nil
    existingPanel.close()
  }
}

// MARK: - View Extensions

extension View {
  /// Presents content in a native resizable NSPanel with frame autosave.
  func modalPanel<Item: Identifiable, Content: View>(
    item: Binding<Item?>,
    title: String = "",
    autosaveName: String,
    defaultSize: CGSize = CGSize(width: 1200, height: 750),
    minSize: CGSize = CGSize(width: 800, height: 500),
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    modifier(ModalPanelModifier(
      item: item,
      title: title,
      autosaveName: autosaveName,
      defaultSize: defaultSize,
      minSize: minSize,
      panelContent: content
    ))
  }

  /// Presents content in a borderless floating panel — no resize, no move,
  /// centered on screen, dismisses on focus loss. Ideal for quick-pick dialogs.
  func floatingPanel<Content: View>(
    isPresented: Binding<Bool>,
    defaultSize: CGSize = CGSize(width: 600, height: 420),
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    modifier(FloatingPanelModifier(
      isPresented: isPresented,
      defaultSize: defaultSize,
      panelContent: content
    ))
  }
}
