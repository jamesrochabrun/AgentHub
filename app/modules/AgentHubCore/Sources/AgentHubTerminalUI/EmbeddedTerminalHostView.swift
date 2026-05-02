//
//  AuxiliaryShellTerminalHostView.swift
//  AgentHub
//

import AppKit

public final class EmbeddedTerminalHostView: NSView {
  public private(set) var mountedTerminalKey: String?
  private weak var mountedTerminalView: NSView?

  public func mount(_ terminal: any EmbeddedTerminalSurface, key: String) {
    mountView(terminal.view, key: key)
  }

  private func mountView(_ terminalView: NSView, key: String) {
    guard mountedTerminalView !== terminalView else {
      mountedTerminalKey = key
      return
    }

    mountedTerminalView?.removeFromSuperview()

    if terminalView.superview !== self {
      terminalView.removeFromSuperview()
      terminalView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(terminalView)
      NSLayoutConstraint.activate([
        terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
        terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        terminalView.topAnchor.constraint(equalTo: topAnchor),
        terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
      ])
    }

    mountedTerminalView = terminalView
    mountedTerminalKey = key
  }

  public func unmountTerminal() {
    mountedTerminalView?.removeFromSuperview()
    mountedTerminalView = nil
    mountedTerminalKey = nil
  }
}

public typealias AuxiliaryShellTerminalHostView = EmbeddedTerminalHostView
