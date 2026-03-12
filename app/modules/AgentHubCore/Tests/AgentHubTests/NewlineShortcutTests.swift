import Testing
@testable import AgentHub

@Suite("NewlineShortcut")
struct NewlineShortcutTests {

  @Test("Raw values are stable")
  func rawValues() {
    #expect(NewlineShortcut.system.rawValue == 0)
    #expect(NewlineShortcut.cmdReturn.rawValue == 1)
    #expect(NewlineShortcut.shiftReturn.rawValue == 2)
  }

  @Test("Default raw value resolves to .system")
  func defaultIsSystem() {
    #expect(NewlineShortcut(rawValue: 0) == .system)
  }

  @Test("Unknown raw value falls back to nil")
  func unknownRawValue() {
    #expect(NewlineShortcut(rawValue: 99) == nil)
  }

  @Test("All cases covered by CaseIterable")
  func allCases() {
    #expect(NewlineShortcut.allCases.count == 3)
  }

  @Test("Labels are non-empty")
  func labels() {
    for shortcut in NewlineShortcut.allCases {
      #expect(!shortcut.label.isEmpty)
    }
  }
}
