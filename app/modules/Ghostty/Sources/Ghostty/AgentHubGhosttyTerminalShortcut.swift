//
//  AgentHubGhosttyTerminalShortcut.swift
//  AgentHub
//

import AppKit
import GhosttySwift

public enum AgentHubGhosttyTerminalShortcut: Equatable {
  case startSearch
  case searchNext
  case searchPrevious
  case openTab
  case openPane
  case closePanel
  case focusPanel(TerminalPanelNavigationDirection)
  case selectTab(TerminalTabNavigationDirection)

  public static func action(for event: NSEvent) -> AgentHubGhosttyTerminalShortcut? {
    action(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      modifierFlags: event.modifierFlags
    )
  }

  public static func action(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> AgentHubGhosttyTerminalShortcut? {
    let flags = normalizedModifierFlags(modifierFlags)
    let key = charactersIgnoringModifiers?.lowercased()

    if flags == [.command] {
      switch keyCode {
      case 123: return .focusPanel(.left)
      case 124: return .focusPanel(.right)
      case 125: return .focusPanel(.down)
      case 126: return .focusPanel(.up)
      default:
        break
      }

      switch key {
      case "f": return .startSearch
      case "g": return .searchNext
      case "t": return .openTab
      case "d": return .openPane
      default: return nil
      }
    }

    if flags == [.command, .shift] {
      switch keyCode {
      case 123: return .selectTab(.previous)
      case 124: return .selectTab(.next)
      default:
        break
      }

      switch key {
      case "g": return .searchPrevious
      case "w": return .closePanel
      default: return nil
      }
    }

    return nil
  }

  private static func normalizedModifierFlags(
    _ flags: NSEvent.ModifierFlags
  ) -> NSEvent.ModifierFlags {
    flags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.numericPad, .function, .capsLock])
  }
}
