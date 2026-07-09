import CoreGraphics
import Foundation
import Testing

@testable import SimulatorPreview

@Suite("SimulatorUIDriver mapping")
struct SimulatorUIDriverMappingTests {
  @Test("Device points normalize against the screen size, clamped")
  func pointNormalization() {
    let screen = CGSize(width: 390, height: 844)
    #expect(SimulatorUIDriver.normalizedPoint(x: 195, y: 422, screenSize: screen)
      == CGPoint(x: 0.5, y: 0.5))
    #expect(SimulatorUIDriver.normalizedPoint(x: -10, y: 9000, screenSize: screen)
      == CGPoint(x: 0, y: 1))
    #expect(SimulatorUIDriver.normalizedPoint(x: 1, y: 1, screenSize: .zero) == nil)
  }

  @Test("Swipe presets move the finger in the named direction")
  func swipePresets() {
    let up = SimulatorUIDriver.swipePreset(direction: "up")
    #expect(up?.from.y ?? 0 > up?.to.y ?? 1)
    let right = SimulatorUIDriver.swipePreset(direction: "RIGHT")
    #expect(right?.from.x ?? 1 < right?.to.x ?? 0)
    #expect(SimulatorUIDriver.swipePreset(direction: "diagonal") == nil)
  }

  @Test("Named keys map to HID usages")
  func namedKeys() {
    #expect(SimulatorUIDriver.keyUsage(named: "Return") == 0x28)
    #expect(SimulatorUIDriver.keyUsage(named: "delete") == 0x2A)
    #expect(SimulatorUIDriver.keyUsage(named: "volume") == nil)
  }
}

@Suite("KeyCodeMapping characters")
struct KeyCodeMappingCharacterTests {
  @Test("Letters map with shift for uppercase")
  func letters() {
    #expect(KeyCodeMapping.hidUsage(forCharacter: "a")! == (0x04, false))
    #expect(KeyCodeMapping.hidUsage(forCharacter: "A")! == (0x04, true))
    #expect(KeyCodeMapping.hidUsage(forCharacter: "z")! == (0x1D, false))
  }

  @Test("Digits and shifted symbols share usages")
  func digitsAndSymbols() {
    #expect(KeyCodeMapping.hidUsage(forCharacter: "1")! == (0x1E, false))
    #expect(KeyCodeMapping.hidUsage(forCharacter: "!")! == (0x1E, true))
    #expect(KeyCodeMapping.hidUsage(forCharacter: "0")! == (0x27, false))
    #expect(KeyCodeMapping.hidUsage(forCharacter: ")")! == (0x27, true))
  }

  @Test("Whitespace and punctuation map; emoji does not")
  func punctuationAndUnsupported() {
    #expect(KeyCodeMapping.hidUsage(forCharacter: " ")! == (0x2C, false))
    #expect(KeyCodeMapping.hidUsage(forCharacter: "\n")! == (0x28, false))
    #expect(KeyCodeMapping.hidUsage(forCharacter: "?")! == (0x38, true))
    #expect(KeyCodeMapping.hidUsage(forCharacter: "_")! == (0x2D, true))
    #expect(KeyCodeMapping.hidUsage(forCharacter: "🎉") == nil)
    #expect(KeyCodeMapping.hidUsage(forCharacter: "é") == nil)
  }
}

@Suite("SimulatorAXElementFinder")
struct SimulatorAXElementFinderTests {
  private func element(
    role: String = "Button",
    label: String? = nil,
    identifier: String? = nil,
    frame: CGRect = CGRect(x: 0, y: 0, width: 44, height: 44),
    children: [SimulatorAXElement] = []
  ) -> SimulatorAXElement {
    SimulatorAXElement(
      role: role, label: label, identifier: identifier, value: nil,
      frame: frame, children: children
    )
  }

  @Test("Exact label match wins over substring matches")
  func exactBeatsSubstring() {
    let root = element(role: "Application", label: "App", frame: CGRect(x: 0, y: 0, width: 390, height: 844), children: [
      element(label: "Store"),
      element(label: "Storefront"),
    ])

    let matches = SimulatorAXElementFinder.matches(in: root, label: "Store", identifier: nil)
    #expect(matches.map(\.label) == ["Store"])
  }

  @Test("Case-insensitive tier applies when exact fails")
  func caseInsensitiveTier() {
    let root = element(role: "Application", frame: CGRect(x: 0, y: 0, width: 390, height: 844), children: [
      element(label: "STORE"),
    ])
    let matches = SimulatorAXElementFinder.matches(in: root, label: "store", identifier: nil)
    #expect(matches.map(\.label) == ["STORE"])
  }

  @Test("Substring tier finds partial labels, in document order")
  func substringTier() {
    let root = element(role: "Application", frame: CGRect(x: 0, y: 0, width: 390, height: 844), children: [
      element(label: "Buy for 500 coins"),
      element(label: "500 coins left"),
    ])
    let matches = SimulatorAXElementFinder.matches(in: root, label: "500 coins", identifier: nil)
    #expect(matches.map(\.label) == ["Buy for 500 coins", "500 coins left"])
  }

  @Test("Identifier queries match identifiers, not labels")
  func identifierMatch() {
    let root = element(role: "Application", frame: CGRect(x: 0, y: 0, width: 390, height: 844), children: [
      element(label: "likeButton"),
      element(label: "Like", identifier: "likeButton"),
    ])
    let matches = SimulatorAXElementFinder.matches(in: root, label: nil, identifier: "likeButton")
    #expect(matches.map(\.label) == ["Like"])
  }

  @Test("Zero-size elements are not tappable and are skipped")
  func zeroSizeSkipped() {
    let root = element(role: "Application", frame: CGRect(x: 0, y: 0, width: 390, height: 844), children: [
      element(label: "Store", frame: CGRect(x: 0, y: 0, width: 0, height: 0)),
      element(label: "Store"),
    ])
    let matches = SimulatorAXElementFinder.matches(in: root, label: "Store", identifier: nil)
    #expect(matches.count == 1)
    #expect(matches.first?.frame.width == 44)
  }

  @Test("Empty queries match nothing")
  func emptyQueries() {
    let root = element(label: "Store")
    #expect(SimulatorAXElementFinder.matches(in: root, label: "  ", identifier: nil).isEmpty)
    #expect(SimulatorAXElementFinder.matches(in: root, label: nil, identifier: nil).isEmpty)
  }
}
