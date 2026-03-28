//
//  AuxiliaryShellTerminalHostView.swift
//  AgentHub
//

import AppKit

public final class AuxiliaryShellTerminalHostView: NSView {
  public private(set) var mountedTerminalKey: String?
  private weak var mountedTerminal: TerminalContainerView?

  public func mount(_ terminal: TerminalContainerView, key: String) {
    guard mountedTerminal !== terminal else {
      mountedTerminalKey = key
      return
    }

    mountedTerminal?.removeFromSuperview()

    if terminal.superview !== self {
      terminal.removeFromSuperview()
      terminal.translatesAutoresizingMaskIntoConstraints = false
      addSubview(terminal)
      NSLayoutConstraint.activate([
        terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
        terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
        terminal.topAnchor.constraint(equalTo: topAnchor),
        terminal.bottomAnchor.constraint(equalTo: bottomAnchor)
      ])
    }

    mountedTerminal = terminal
    mountedTerminalKey = key
  }

  public func unmountTerminal() {
    mountedTerminal?.removeFromSuperview()
    mountedTerminal = nil
    mountedTerminalKey = nil
  }
}
