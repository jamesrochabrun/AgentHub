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

  func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?)
  func configure(
    sessionId: String?,
    projectPath: String,
    cliConfiguration: CLICommandConfiguration,
    initialPrompt: String?,
    initialInputText: String?,
    isDark: Bool,
    dangerouslySkipPermissions: Bool,
    permissionModePlan: Bool,
    worktreeName: String?,
    metadataStore: SessionMetadataStore?
  )
  func configureShell(projectPath: String, isDark: Bool, shellPath: String?)
  func restart(sessionId: String?, projectPath: String, cliConfiguration: CLICommandConfiguration)
  func terminateProcess()
  func resetPromptDeliveryFlag()
  func sendPromptIfNeeded(_ prompt: String)
  func submitPromptImmediately(_ prompt: String) -> Bool
  func typeText(_ text: String)
  func typeInitialTextIfNeeded(_ text: String)
  func syncAppearance(isDark: Bool, fontSize: CGFloat, fontFamily: String, theme: RuntimeTheme?)
  func focus()
  func captureWorkspaceSnapshot() -> TerminalWorkspaceSnapshot?
  func restoreWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSnapshot)
}

public extension EmbeddedTerminalSurface {
  var onWorkspaceChanged: ((TerminalWorkspaceSnapshot) -> Void)? {
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
  public init() {}

  public func makeSurface(for backend: EmbeddedTerminalBackend) -> any EmbeddedTerminalSurface {
    switch backend {
    case .ghostty:
      return AgentHubGhosttyTerminalSurface()
    case .regular:
      return TerminalContainerView()
    }
  }
}

extension TerminalContainerView: EmbeddedTerminalSurface {
  public var view: NSView { self }

  public func updateContext(terminalSessionKey: String?, sessionViewModel: CLISessionsViewModel?) {
    self.terminalSessionKey = terminalSessionKey
    self.sessionViewModel = sessionViewModel
  }

  public func focus() {
    guard let terminalView, let window = terminalView.window else { return }
    window.makeFirstResponder(terminalView)
  }
}
