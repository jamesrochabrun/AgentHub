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
  case openPane(axis: TerminalSplitAxis)
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

    if flags == [.command, .control] {
      switch keyCode {
      case 123: return .focusPanel(.left)
      case 124: return .focusPanel(.right)
      case 125: return .focusPanel(.down)
      case 126: return .focusPanel(.up)
      default:
        return nil
      }
    }

    if flags == [.command] {
      switch key {
      case "f": return .startSearch
      case "g": return .searchNext
      case "t": return .openTab
      case "d": return .openPane(axis: .horizontal)
      default: return nil
      }
    }

    if flags == [.command, .control, .shift] {
      switch keyCode {
      case 123: return .selectTab(.previous)
      case 124: return .selectTab(.next)
      default:
        return nil
      }
    }

    if flags == [.command, .shift] {
      switch key {
      case "d": return .openPane(axis: .vertical)
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
