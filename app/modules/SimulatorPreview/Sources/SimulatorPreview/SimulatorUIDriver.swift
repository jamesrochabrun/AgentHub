import CoreGraphics
import Foundation

// Headless UI interaction with a booted simulator — the engine behind the
// `agenthub_simulator_tap` / `_swipe` / `_type` / `_press_button` MCP tools.
// Reuses the same Indigo HID path as the panel's live mirror (no TCC prompts,
// no window server, nothing leaves the machine); this is the bundled
// equivalent of what `idb ui` / AXe do, so agents can drive an app to a
// screen and verify it without external tooling.

public enum SimulatorUIDriverError: LocalizedError {
  case hidUnavailable(detail: String)
  case keyboardUnavailable
  case buttonsUnavailable
  case unsupportedCharacters(String)

  public var errorDescription: String? {
    switch self {
    case .hidUnavailable(let detail):
      return "Simulator HID injection is unavailable: \(detail)"
    case .keyboardUnavailable:
      return "Simulator keyboard injection is unavailable on this machine."
    case .buttonsUnavailable:
      return "Simulator hardware-button injection is unavailable on this machine."
    case .unsupportedCharacters(let characters):
      return "These characters cannot be typed via HID key events (US layout only): \(characters). Rephrase the text or type it another way."
    }
  }
}

/// Injects synthetic touches, swipes, text, and hardware buttons into a booted
/// simulator. Coordinates are normalized (0…1, top-left origin) — the same
/// space the panel's mirror uses; callers convert from device points using the
/// screen bounds (the AX root frame).
public final class SimulatorUIDriver {
  private let developerDir: String

  public init(developerDir: String = XcodeDeveloperDirectory.resolved) {
    self.developerDir = developerDir
  }

  /// Converts a point in device points (top-left origin) to the normalized
  /// space HID expects, clamped into the screen.
  public static func normalizedPoint(x: Double, y: Double, screenSize: CGSize) -> CGPoint? {
    guard screenSize.width > 0, screenSize.height > 0 else { return nil }
    return CGPoint(
      x: min(max(x / screenSize.width, 0), 1),
      y: min(max(y / screenSize.height, 0), 1)
    )
  }

  /// Centered swipe presets in normalized space. `direction` is the direction
  /// the finger moves (content scrolls the opposite way).
  public static func swipePreset(direction: String) -> (from: CGPoint, to: CGPoint)? {
    switch direction.lowercased() {
    case "up": return (CGPoint(x: 0.5, y: 0.7), CGPoint(x: 0.5, y: 0.3))
    case "down": return (CGPoint(x: 0.5, y: 0.3), CGPoint(x: 0.5, y: 0.7))
    case "left": return (CGPoint(x: 0.8, y: 0.5), CGPoint(x: 0.2, y: 0.5))
    case "right": return (CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5))
    default: return nil
    }
  }

  /// Tap (or long-press with `holdSeconds`) at a normalized location.
  public func tap(
    udid: String,
    normalizedX: Double,
    normalizedY: Double,
    holdSeconds: TimeInterval = 0
  ) throws {
    let injector = try makeInjector(udid: udid)
    defer { injector.teardown() }
    injector.sendTouch(type: .began, normalizedX: normalizedX, normalizedY: normalizedY)
    Thread.sleep(forTimeInterval: max(holdSeconds, 0.06))
    injector.sendTouch(type: .ended, normalizedX: normalizedX, normalizedY: normalizedY)
  }

  /// Finger-down drag from one normalized point to another.
  public func swipe(
    udid: String,
    from: CGPoint,
    to: CGPoint,
    durationSeconds: TimeInterval = 0.3
  ) throws {
    let injector = try makeInjector(udid: udid)
    defer { injector.teardown() }

    let stepDelay: TimeInterval = 0.016
    let steps = max(2, Int((max(durationSeconds, 0.05) / stepDelay).rounded()))
    injector.sendTouch(type: .began, normalizedX: from.x, normalizedY: from.y)
    Thread.sleep(forTimeInterval: stepDelay)
    for step in 1...steps {
      let progress = Double(step) / Double(steps)
      injector.sendTouch(
        type: .moved,
        normalizedX: from.x + (to.x - from.x) * progress,
        normalizedY: from.y + (to.y - from.y) * progress
      )
      Thread.sleep(forTimeInterval: stepDelay)
    }
    injector.sendTouch(type: .ended, normalizedX: to.x, normalizedY: to.y)
  }

  /// Types text as HID key events into the focused field. Fails up front —
  /// before any key is sent — when the text contains unmappable characters.
  public func typeText(udid: String, text: String) throws {
    let unsupported = text.filter { KeyCodeMapping.hidUsage(forCharacter: $0) == nil }
    guard unsupported.isEmpty else {
      throw SimulatorUIDriverError.unsupportedCharacters(
        String(Set(unsupported).sorted().prefix(20))
      )
    }

    let injector = try makeInjector(udid: udid)
    defer { injector.teardown() }
    guard injector.supportsKeyboard else {
      throw SimulatorUIDriverError.keyboardUnavailable
    }

    for character in text {
      guard let mapping = KeyCodeMapping.hidUsage(forCharacter: character) else { continue }
      if mapping.shift {
        injector.sendKey(direction: .down, usage: KeyCodeMapping.shiftUsage)
      }
      injector.sendKey(direction: .down, usage: mapping.usage)
      injector.sendKey(direction: .up, usage: mapping.usage)
      if mapping.shift {
        injector.sendKey(direction: .up, usage: KeyCodeMapping.shiftUsage)
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  /// Presses a named key (return, delete, escape, tab, arrows) `times` times.
  public func pressKey(udid: String, usage: UInt32, times: Int = 1) throws {
    let injector = try makeInjector(udid: udid)
    defer { injector.teardown() }
    guard injector.supportsKeyboard else {
      throw SimulatorUIDriverError.keyboardUnavailable
    }
    for _ in 0..<max(times, 1) {
      injector.sendKey(direction: .down, usage: usage)
      injector.sendKey(direction: .up, usage: usage)
      Thread.sleep(forTimeInterval: 0.03)
    }
  }

  /// Named keys exposed to agents for `pressKey`.
  public static func keyUsage(named name: String) -> UInt32? {
    switch name.lowercased() {
    case "return", "enter": return 0x28
    case "delete", "backspace": return 0x2A
    case "escape": return 0x29
    case "tab": return 0x2B
    case "space": return 0x2C
    case "left": return 0x50
    case "right": return 0x4F
    case "down": return 0x51
    case "up": return 0x52
    default: return nil
    }
  }

  /// Hardware buttons. `swipeHome` is the home gesture for edge-to-edge
  /// devices; the injector performs it on its own serial queue, so give it a
  /// beat to complete before capturing.
  public func pressButton(udid: String, button: SimulatorHardwareButton) throws {
    let injector = try makeInjector(udid: udid)
    // `swipeHome`/`appSwitcher` run async on the injector's button queue;
    // keep the injector alive long enough for the gesture to finish.
    let holdForGesture: TimeInterval
    switch button {
    case .swipeHome, .appSwitcher: holdForGesture = 0.6
    case .home, .lock: holdForGesture = 0.1
    }
    injector.sendButton(button, deviceUDID: udid)
    Thread.sleep(forTimeInterval: holdForGesture)
    injector.teardown()
  }

  private func makeInjector(udid: String) throws -> HIDInjector {
    let injector = HIDInjector(developerDir: developerDir)
    do {
      try injector.setup(deviceUDID: udid)
    } catch {
      throw SimulatorUIDriverError.hidUnavailable(detail: error.localizedDescription)
    }
    guard injector.isReady else {
      throw SimulatorUIDriverError.hidUnavailable(detail: "HID client did not become ready")
    }
    return injector
  }
}
