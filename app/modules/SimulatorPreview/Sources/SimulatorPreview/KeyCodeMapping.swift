import Foundation

/// Translates macOS virtual key codes (NSEvent.keyCode) into USB HID usage
/// codes (usage page 0x07) for keyboard injection into the simulator.
///
/// Only the keys an agent-built app commonly needs are mapped: letters, digits,
/// return/delete/escape/tab/space, and arrows. Unmapped keys return nil and are
/// ignored rather than guessed.
public enum KeyCodeMapping {
  /// macOS virtual keycode → USB HID usage.
  public static func hidUsage(forVirtualKeyCode keyCode: UInt16) -> UInt32? {
    table[keyCode]
  }

  /// USB HID usage for the left-shift modifier key.
  public static let shiftUsage: UInt32 = 0xE1

  /// Character → (HID usage, needs shift) for text typing on a US layout.
  /// Covers what agent-built apps commonly type: letters, digits, space,
  /// newline (return), and US-keyboard punctuation. Unmapped characters
  /// return nil so callers can report them instead of guessing.
  public static func hidUsage(forCharacter character: Character) -> (usage: UInt32, shift: Bool)? {
    if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 {
      // Letters: HID 'a' = 0x04; uppercase is shift + same usage.
      if scalar.value >= 97, scalar.value <= 122 {  // a-z
        return (0x04 + scalar.value - 97, false)
      }
      if scalar.value >= 65, scalar.value <= 90 {  // A-Z
        return (0x04 + scalar.value - 65, true)
      }
      // Digits: HID '1' = 0x1E ... '9' = 0x26, '0' = 0x27.
      if scalar.value >= 49, scalar.value <= 57 {  // 1-9
        return (0x1E + scalar.value - 49, false)
      }
      if scalar.value == 48 {  // 0
        return (0x27, false)
      }
    }
    return characterTable[character]
  }

  private static let characterTable: [Character: (usage: UInt32, shift: Bool)] = [
    " ": (0x2C, false),
    "\n": (0x28, false),
    "\t": (0x2B, false),
    "-": (0x2D, false), "_": (0x2D, true),
    "=": (0x2E, false), "+": (0x2E, true),
    "[": (0x2F, false), "{": (0x2F, true),
    "]": (0x30, false), "}": (0x30, true),
    "\\": (0x31, false), "|": (0x31, true),
    ";": (0x33, false), ":": (0x33, true),
    "'": (0x34, false), "\"": (0x34, true),
    "`": (0x35, false), "~": (0x35, true),
    ",": (0x36, false), "<": (0x36, true),
    ".": (0x37, false), ">": (0x37, true),
    "/": (0x38, false), "?": (0x38, true),
    "!": (0x1E, true), "@": (0x1F, true), "#": (0x20, true),
    "$": (0x21, true), "%": (0x22, true), "^": (0x23, true),
    "&": (0x24, true), "*": (0x25, true), "(": (0x26, true),
    ")": (0x27, true),
  ]

  private static let table: [UInt16: UInt32] = [
    // Letters (kVK_ANSI_A ...). HID 'a' = 0x04.
    0x00: 0x04,  // A
    0x0B: 0x05,  // B
    0x08: 0x06,  // C
    0x02: 0x07,  // D
    0x0E: 0x08,  // E
    0x03: 0x09,  // F
    0x05: 0x0A,  // G
    0x04: 0x0B,  // H
    0x22: 0x0C,  // I
    0x26: 0x0D,  // J
    0x28: 0x0E,  // K
    0x25: 0x0F,  // L
    0x2E: 0x10,  // M
    0x2D: 0x11,  // N
    0x1F: 0x12,  // O
    0x23: 0x13,  // P
    0x0C: 0x14,  // Q
    0x0F: 0x15,  // R
    0x01: 0x16,  // S
    0x11: 0x17,  // T
    0x20: 0x18,  // U
    0x09: 0x19,  // V
    0x0D: 0x1A,  // W
    0x07: 0x1B,  // X
    0x10: 0x1C,  // Y
    0x06: 0x1D,  // Z
    // Digits. HID '1' = 0x1E ... '0' = 0x27.
    0x12: 0x1E,  // 1
    0x13: 0x1F,  // 2
    0x14: 0x20,  // 3
    0x15: 0x21,  // 4
    0x17: 0x22,  // 5
    0x16: 0x23,  // 6
    0x1A: 0x24,  // 7
    0x1C: 0x25,  // 8
    0x19: 0x26,  // 9
    0x1D: 0x27,  // 0
    // Control keys.
    0x24: 0x28,  // Return
    0x30: 0x2B,  // Tab
    0x31: 0x2C,  // Space
    0x33: 0x2A,  // Delete (Backspace)
    0x35: 0x29,  // Escape
    0x75: 0x4C,  // Forward Delete
    // Punctuation.
    0x1B: 0x2D,  // -
    0x18: 0x2E,  // =
    0x21: 0x2F,  // [
    0x1E: 0x30,  // ]
    0x2A: 0x31,  // backslash
    0x29: 0x33,  // ;
    0x27: 0x34,  // '
    0x32: 0x35,  // `
    0x2B: 0x36,  // ,
    0x2F: 0x37,  // .
    0x2C: 0x38,  // /
    // Arrows.
    0x7B: 0x50,  // Left
    0x7C: 0x4F,  // Right
    0x7D: 0x51,  // Down
    0x7E: 0x52,  // Up
  ]
}
