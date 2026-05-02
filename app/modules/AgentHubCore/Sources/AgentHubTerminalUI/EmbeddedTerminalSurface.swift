//
//  EmbeddedTerminalSurface.swift
//  AgentHub
//

import AppKit
import SwiftUI

@MainActor
public protocol EmbeddedTerminalSurface: AnyObject {
  var view: NSView { get }
  var currentProcessPID: Int32? { get }
  var onUserInteraction: (() -> Void)? { get set }
  var onRequestShowEditor: (() -> Void)? { get set }
  var consumeQueuedWebPreviewContextOnSubmit: (() -> String?)? { get set }
  var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)? { get set }
  var onOpenFile: ((String, Int?) -> Void)? { get set }

  func updateContext(terminalSessionKey: String?)
  func configure(
    launch: Result<EmbeddedTerminalLaunch, EmbeddedTerminalLaunchError>,
    projectPath: String,
    initialInputText: String?,
    isDark: Bool
  )
  func configureShell(
    launch: EmbeddedTerminalLaunch,
    projectPath: String,
    isDark: Bool
  )
  func restart(launch: Result<EmbeddedTerminalLaunch, EmbeddedTerminalLaunchError>, projectPath: String)
  func terminateProcess()
  func resetPromptDeliveryFlag()
  func sendPromptIfNeeded(_ prompt: String)
  func submitPromptImmediately(_ prompt: String) -> Bool
  func typeText(_ text: String)
  func typeInitialTextIfNeeded(_ text: String)
  func syncAppearance(
    isDark: Bool,
    fontSize: CGFloat,
    fontFamily: String,
    theme: TerminalAppearanceTheme?
  )
  func focus()
  func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot?
  func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot)
}

public extension EmbeddedTerminalSurface {
  var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)? {
    get { nil }
    set {}
  }

  var onOpenFile: ((String, Int?) -> Void)? {
    get { nil }
    set {}
  }

  func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot? {
    nil
  }

  func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot) {}
}

public protocol EmbeddedTerminalSurfaceFactory {
  @MainActor
  func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface
}

public struct DefaultEmbeddedTerminalSurfaceFactory: EmbeddedTerminalSurfaceFactory {
  private let ghosttyProvider: (@MainActor () -> any EmbeddedTerminalSurface)?

  /// - Parameter ghosttyProvider: Closure that builds a Ghostty-backed surface.
  ///   Wired by the app target after importing the `Ghostty` module. When
  ///   omitted (e.g. unit tests, or builds where the Ghostty module is absent),
  ///   selecting `.ghostty` silently falls back to the regular SwiftTerm
  ///   surface so core code keeps functioning standalone.
  public init(ghosttyProvider: (@MainActor () -> any EmbeddedTerminalSurface)? = nil) {
    self.ghosttyProvider = ghosttyProvider
  }

  public func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    switch backend {
    case .ghostty:
      if let ghosttyProvider {
        return ghosttyProvider()
      }
      return TerminalContainerView()
    case .regular:
      return TerminalContainerView()
    }
  }
}

extension TerminalContainerView: EmbeddedTerminalSurface {
  public var view: NSView { self }

  public func updateContext(terminalSessionKey: String?) {
    self.terminalSessionKey = terminalSessionKey
  }

  public func focus() {
    guard let terminalView, let window = terminalView.window else { return }
    window.makeFirstResponder(terminalView)
  }
}
