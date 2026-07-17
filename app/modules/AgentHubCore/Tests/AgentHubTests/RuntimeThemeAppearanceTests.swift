import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentHubCore

@MainActor
@Suite("Runtime theme appearance")
struct RuntimeThemeAppearanceTests {
  @Test("Appearance-specific brand colors resolve for light and dark mode")
  func appearanceSpecificBrandColorsResolve() throws {
    let runtime = try runtimeTheme(
      light: ["#445566", "#556677", "#667788"],
      dark: ["#AABBCC", "#BBCCDD", "#CCDDEE"]
    )

    #expect(try hexString(runtime.brandPrimary, appearance: .aqua) == "#445566")
    #expect(try hexString(runtime.brandSecondary, appearance: .aqua) == "#556677")
    #expect(try hexString(runtime.brandTertiary, appearance: .aqua) == "#667788")
    #expect(try hexString(runtime.brandPrimary, appearance: .darkAqua) == "#AABBCC")
    #expect(try hexString(runtime.brandSecondary, appearance: .darkAqua) == "#BBCCDD")
    #expect(try hexString(runtime.brandTertiary, appearance: .darkAqua) == "#CCDDEE")
  }

  @Test("Legacy brand colors remain unchanged in both appearances")
  func legacyBrandColorsRemainAppearanceIndependent() throws {
    let runtime = try runtimeTheme()

    #expect(try hexString(runtime.brandPrimary, appearance: .aqua) == "#112233")
    #expect(try hexString(runtime.brandPrimary, appearance: .darkAqua) == "#112233")
  }

  @Test("Bundled Ghostty theme uses readable light and dark palettes")
  func bundledGhosttyThemeUsesAppearanceSpecificPalettes() throws {
    let theme = try YAMLThemeParser().parse(fileURL: bundledGhosttyThemeURL())
    let runtime = RuntimeTheme(from: theme, sourceFileName: "ghostty.yaml")

    #expect(try hexString(runtime.brandPrimary, appearance: .aqua) == "#4A5568")
    #expect(try hexString(runtime.brandSecondary, appearance: .aqua) == "#2D3748")
    #expect(try hexString(runtime.brandTertiary, appearance: .aqua) == "#64748B")
    #expect(try hexString(runtime.brandPrimary, appearance: .darkAqua) == "#A0AEC0")
    #expect(try hexString(runtime.brandSecondary, appearance: .darkAqua) == "#2D3748")
    #expect(try hexString(runtime.brandTertiary, appearance: .darkAqua) == "#CBD5E0")
  }

  @Test("Invalid appearance-specific brand colors are rejected")
  func invalidAppearanceSpecificBrandColorIsRejected() {
    #expect(throws: ThemeError.self) {
      _ = try runtimeTheme(
        light: ["not-a-color", "#556677", "#667788"]
      )
    }
  }

  private func runtimeTheme(
    light: [String]? = nil,
    dark: [String]? = nil
  ) throws -> RuntimeTheme {
    var lines = [
      "name: \"Adaptive\"",
      "version: \"1.0\"",
      "colors:",
      "  brand:",
      "    primary: \"#112233\"",
      "    secondary: \"#223344\"",
      "    tertiary: \"#334455\"",
    ]
    appendVariant(light, named: "light", to: &lines)
    appendVariant(dark, named: "dark", to: &lines)

    let yaml = lines.joined(separator: "\n")
    let theme = try YAMLThemeParser().parse(data: Data(yaml.utf8))
    return RuntimeTheme(from: theme, sourceFileName: "adaptive.yaml")
  }

  private func appendVariant(
    _ colors: [String]?,
    named name: String,
    to lines: inout [String]
  ) {
    guard let colors, colors.count == 3 else { return }
    lines.append(contentsOf: [
      "    \(name):",
      "      primary: \"\(colors[0])\"",
      "      secondary: \"\(colors[1])\"",
      "      tertiary: \"\(colors[2])\"",
    ])
  }

  private func bundledGhosttyThemeURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/AgentHub/Design/Theme/BundledThemes/ghostty.yaml")
  }

  private func hexString(
    _ color: Color,
    appearance appearanceName: NSAppearance.Name
  ) throws -> String {
    let appearance = try #require(NSAppearance(named: appearanceName))
    var resolvedColor: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolvedColor = NSColor(color).usingColorSpace(.sRGB)
    }
    return Color.hexString(from: try #require(resolvedColor))
  }
}
