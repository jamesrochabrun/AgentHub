//
//  TerminalAppearanceTheme.swift
//  AgentHub
//

import AppKit

public struct TerminalAppearanceTheme {
  public let id: String
  public let terminalBackground: NSColor?
  public let terminalForeground: NSColor?
  public let terminalCursor: NSColor?

  public init(
    id: String,
    terminalBackground: NSColor?,
    terminalForeground: NSColor?,
    terminalCursor: NSColor?
  ) {
    self.id = id
    self.terminalBackground = terminalBackground
    self.terminalForeground = terminalForeground
    self.terminalCursor = terminalCursor
  }
}
