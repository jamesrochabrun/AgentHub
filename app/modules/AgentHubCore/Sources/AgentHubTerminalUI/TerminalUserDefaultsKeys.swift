//
//  TerminalUserDefaultsKeys.swift
//  AgentHub
//

import Foundation

public enum TerminalUserDefaultsKeys {
  public static let keyPrefix = "com.agenthub."

  public static let terminalFontSize = "\(keyPrefix)terminal.fontSize"
  public static let terminalFontFamily = "\(keyPrefix)terminal.fontFamily"
  public static let terminalBackend = "\(keyPrefix)terminal.backend"
  public static let terminalGhosttyConfigPath = "\(keyPrefix)terminal.ghosttyConfigPath"
  public static let terminalNewlineShortcut = "\(keyPrefix)terminal.newlineShortcut"
  public static let terminalFileOpenEditor = "\(keyPrefix)terminal.fileOpenEditor"
}
