import Testing

@testable import SimulatorPreview

@Suite("KeyCodeMapping")
struct KeyCodeMappingTests {
  @Test("letter A maps to HID 0x04")
  func letterA() {
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x00) == 0x04)
  }

  @Test("return / delete / escape / space map correctly")
  func controlKeys() {
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x24) == 0x28)  // Return
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x33) == 0x2A)  // Delete
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x35) == 0x29)  // Escape
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x31) == 0x2C)  // Space
  }

  @Test("digit 1 maps to HID 0x1E and 0 to 0x27")
  func digits() {
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x12) == 0x1E)
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x1D) == 0x27)
  }

  @Test("arrows map into the HID arrow block")
  func arrows() {
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x7B) == 0x50)  // Left
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0x7E) == 0x52)  // Up
  }

  @Test("unmapped keycode returns nil")
  func unmapped() {
    #expect(KeyCodeMapping.hidUsage(forVirtualKeyCode: 0xFFFF) == nil)
  }
}
