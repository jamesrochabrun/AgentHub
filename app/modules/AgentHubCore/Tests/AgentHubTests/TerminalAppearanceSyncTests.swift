import Foundation
import Testing

@testable import AgentHubCore

@Suite("TerminalAppearanceSync")
struct TerminalAppearanceSyncTests {
  private let surfaceA = UUID()
  private let surfaceB = UUID()

  // MARK: - Font fingerprint

  @Test("First font application (nil state) applies")
  func firstFontApplicationApplies() {
    let incoming = TerminalAppearanceSync.FontFingerprint(
      family: "SF Mono",
      size: 12,
      surfaceIDs: [surfaceA]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: nil, incoming: incoming))
  }

  @Test("Unchanged font fingerprint skips")
  func unchangedFontFingerprintSkips() {
    let current = TerminalAppearanceSync.FontFingerprint(
      family: "SF Mono",
      size: 12,
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.FontFingerprint(
      family: "SF Mono",
      size: 12,
      surfaceIDs: [surfaceA]
    )

    #expect(!TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))
  }

  @Test("Font size change applies")
  func fontSizeChangeApplies() {
    let current = TerminalAppearanceSync.FontFingerprint(
      family: "SF Mono",
      size: 12,
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.FontFingerprint(
      family: "SF Mono",
      size: 14,
      surfaceIDs: [surfaceA]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))
  }

  @Test("Font family change applies")
  func fontFamilyChangeApplies() {
    let current = TerminalAppearanceSync.FontFingerprint(
      family: "SF Mono",
      size: 12,
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.FontFingerprint(
      family: "Menlo",
      size: 12,
      surfaceIDs: [surfaceA]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))
  }

  @Test("New terminal surface applies font even when font values are unchanged")
  func newSurfaceAppliesFont() {
    let current = TerminalAppearanceSync.FontFingerprint(
      family: "SF Mono",
      size: 12,
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.FontFingerprint(
      family: "SF Mono",
      size: 12,
      surfaceIDs: [surfaceA, surfaceB]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))
  }

  // MARK: - Color fingerprint

  @Test("First color application (nil state) applies")
  func firstColorApplicationApplies() {
    let incoming = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: nil,
      themeCursor: nil,
      surfaceIDs: [surfaceA]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: nil, incoming: incoming))
  }

  @Test("Unchanged color fingerprint skips")
  func unchangedColorFingerprintSkips() {
    let current = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#181825",
      themeCursor: "#F5E0DC",
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#181825",
      themeCursor: "#F5E0DC",
      surfaceIDs: [surfaceA]
    )

    #expect(!TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))
  }

  @Test("YAML hot-reload: changed theme values apply even when the theme id is unchanged")
  func themeValueChangeWithSameIdApplies() {
    // YAML themes hot-reload in place: the theme id stays stable while the
    // resolved terminal colors change. The fingerprint keys on resolved
    // values (the id is intentionally not part of it), so an in-place edit
    // of terminal.background must produce a different fingerprint.
    let beforeReload = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#181825",
      themeCursor: "#F5E0DC",
      surfaceIDs: [surfaceA]
    )
    let afterReload = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#1E1E2E",
      themeCursor: "#F5E0DC",
      surfaceIDs: [surfaceA]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: beforeReload, incoming: afterReload))
  }

  @Test("Cursor-only theme change applies")
  func cursorOnlyThemeChangeApplies() {
    let current = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#181825",
      themeCursor: "#F5E0DC",
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#181825",
      themeCursor: "#CC785C",
      surfaceIDs: [surfaceA]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))
  }

  @Test("Color scheme flip applies")
  func colorSchemeFlipApplies() {
    let current = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: nil,
      themeCursor: nil,
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.ColorFingerprint(
      isDark: false,
      themeBackground: nil,
      themeCursor: nil,
      surfaceIDs: [surfaceA]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))
  }

  @Test("Theme terminal colors are ignored in light mode")
  func themeColorsIgnoredInLightMode() {
    // updateColors only honors theme background/cursor in dark mode, so a
    // theme switch while in light mode must not force a repaint...
    let current = TerminalAppearanceSync.ColorFingerprint(
      isDark: false,
      themeBackground: "#181825",
      themeCursor: "#F5E0DC",
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.ColorFingerprint(
      isDark: false,
      themeBackground: "#1E1E2E",
      themeCursor: "#CC785C",
      surfaceIDs: [surfaceA]
    )

    #expect(!TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))

    // ...but the same values in dark mode are honored and must apply.
    let dark = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#1E1E2E",
      themeCursor: "#CC785C",
      surfaceIDs: [surfaceA]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: current, incoming: dark))
    #expect(dark.themeBackground == "#1E1E2E")
    #expect(dark.themeCursor == "#CC785C")
  }

  @Test("New terminal surface applies colors even when color values are unchanged")
  func newSurfaceAppliesColors() {
    let current = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#181825",
      themeCursor: "#F5E0DC",
      surfaceIDs: [surfaceA]
    )
    let incoming = TerminalAppearanceSync.ColorFingerprint(
      isDark: true,
      themeBackground: "#181825",
      themeCursor: "#F5E0DC",
      surfaceIDs: [surfaceA, surfaceB]
    )

    #expect(TerminalAppearanceSync.shouldApply(current: current, incoming: incoming))
  }
}
