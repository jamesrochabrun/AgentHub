import AppKit
import Foundation
import SwiftUI
import Testing

@testable import AgentHubCore

@Suite("Theme selection policy", .serialized)
struct ThemeSelectionPolicyTests {

  @Test("Ghostty backend only exposes the Ghostty bundled YAML theme")
  func ghosttyBackendOnlyExposesGhosttyTheme() {
    #expect(ThemeSelectionPolicy.bundledYAMLThemeFileIds(for: .ghostty) == ["ghostty.yaml"])
  }

  @Test("Regular backend exposes regular bundled YAML themes without Ghostty")
  func regularBackendHidesGhosttyTheme() {
    let fileIds = ThemeSelectionPolicy.bundledYAMLThemeFileIds(for: .regular)

    #expect(fileIds.contains("singularity.yaml"))
    #expect(fileIds.contains("nebula.yaml"))
    #expect(!fileIds.contains("ghostty.yaml"))
  }

  @Test("Ghostty theme aliases normalize to ghostty.yaml")
  func ghosttyThemeAliasesNormalize() {
    #expect(ThemeSelectionPolicy.matchingBundledYAMLFileId(for: "ghostty") == "ghostty.yaml")
    #expect(ThemeSelectionPolicy.matchingBundledYAMLFileId(for: "ghostty.yaml") == "ghostty.yaml")
    #expect(ThemeSelectionPolicy.matchingBundledYAMLFileId(for: "ghostty.yml") == "ghostty.yaml")
    #expect(ThemeSelectionPolicy.canonicalThemeId(for: "ghostty", backend: .ghostty) == "ghostty.yaml")
    #expect(ThemeSelectionPolicy.canonicalThemeId(for: "ghostty", backend: .regular) == nil)
  }

  @Test("Switching to Ghostty preserves previous regular theme and selects Ghostty")
  func switchingToGhosttyPreservesRegularTheme() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("rigel.yml", forKey: AgentHubDefaults.selectedTheme)

    let selectedThemeId = ThemeSelectionPolicy.coercePersistedThemeSelection(
      defaults: defaults,
      backend: .ghostty
    )

    #expect(selectedThemeId == "ghostty.yaml")
    #expect(defaults.string(forKey: AgentHubDefaults.selectedTheme) == "ghostty.yaml")
    #expect(defaults.string(forKey: AgentHubDefaults.previousNonGhosttyTheme) == "rigel.yaml")
  }

  @Test("Switching back to Regular restores previous regular theme")
  func switchingBackToRegularRestoresPreviousTheme() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("ghostty.yaml", forKey: AgentHubDefaults.selectedTheme)
    defaults.set("vela.yaml", forKey: AgentHubDefaults.previousNonGhosttyTheme)

    let selectedThemeId = ThemeSelectionPolicy.coercePersistedThemeSelection(
      defaults: defaults,
      backend: .regular
    )

    #expect(selectedThemeId == "vela.yaml")
    #expect(defaults.string(forKey: AgentHubDefaults.selectedTheme) == "vela.yaml")
    #expect(defaults.string(forKey: AgentHubDefaults.previousNonGhosttyTheme) == "vela.yaml")
  }

  @Test("Regular backend falls back to Singularity when previous regular theme is invalid")
  func regularBackendFallsBackWhenPreviousThemeIsInvalid() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("ghostty.yaml", forKey: AgentHubDefaults.selectedTheme)
    defaults.set("not-a-theme", forKey: AgentHubDefaults.previousNonGhosttyTheme)

    let selectedThemeId = ThemeSelectionPolicy.coercePersistedThemeSelection(
      defaults: defaults,
      backend: .regular
    )

    #expect(selectedThemeId == "singularity.yaml")
    #expect(defaults.string(forKey: AgentHubDefaults.selectedTheme) == "singularity.yaml")
    #expect(defaults.string(forKey: AgentHubDefaults.previousNonGhosttyTheme) == "singularity.yaml")
  }

  @Test("Regular backend preserves custom YAML theme selections")
  func regularBackendPreservesCustomYAMLThemeSelections() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("custom-theme.yml", forKey: AgentHubDefaults.selectedTheme)

    let selectedThemeId = ThemeSelectionPolicy.coercePersistedThemeSelection(
      defaults: defaults,
      backend: .regular
    )

    #expect(selectedThemeId == "custom-theme.yml")
    #expect(defaults.string(forKey: AgentHubDefaults.selectedTheme) == "custom-theme.yml")
    #expect(defaults.string(forKey: AgentHubDefaults.previousNonGhosttyTheme) == "custom-theme.yml")
  }

  @Test("Ghostty YAML uses Singularity highlights with Ghostty backgrounds")
  func ghosttyYAMLUsesSingularityHighlightsWithGhosttyBackgrounds() throws {
    let parser = YAMLThemeParser()
    let theme = try parser.parse(fileURL: ghosttyThemeURL())
    let runtime = RuntimeTheme(from: theme, sourceFileName: "ghostty.yaml")
    let primaryDarkHex = try hexString(from: runtime.brandPrimary, appearance: .darkAqua)
    let secondaryDarkHex = try hexString(from: runtime.brandSecondary, appearance: .darkAqua)
    let tertiaryDarkHex = try hexString(from: runtime.brandTertiary, appearance: .darkAqua)
    let primaryLightHex = try hexString(from: runtime.brandPrimary, appearance: .aqua)
    let secondaryLightHex = try hexString(from: runtime.brandSecondary, appearance: .aqua)
    let tertiaryLightHex = try hexString(from: runtime.brandTertiary, appearance: .aqua)
    let backgroundDarkHex = try hexString(from: #require(runtime.backgroundDark))
    let backgroundLightHex = try hexString(from: #require(runtime.backgroundLight))
    let terminalBackgroundHex = try Color.hexString(from: #require(runtime.terminalBackground))

    #expect(primaryDarkHex == "#A0AEC0")
    #expect(secondaryDarkHex == "#2D3748")
    #expect(tertiaryDarkHex == "#CBD5E0")
    #expect(primaryLightHex == "#4A5568")
    #expect(secondaryLightHex == "#2D3748")
    #expect(tertiaryLightHex == "#64748B")
    #expect(runtime.hasCustomBackgrounds == true)
    #expect(backgroundDarkHex == "#252627")
    #expect(backgroundLightHex == "#FBFBFF")
    #expect(runtime.expandedContentBackgroundDark == nil)
    #expect(terminalBackgroundHex == "#252627")
    #expect(runtime.terminalAnsiColors?.count == 16)
  }

  private func makeDefaults() throws -> (UserDefaults, String) {
    let suiteName = "ThemeSelectionPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }

  private func ghosttyThemeURL() -> URL {
    appRootURL()
      .appendingPathComponent("modules/AgentHubCore/Sources/AgentHub/Design/Theme/BundledThemes/ghostty.yaml")
  }

  private func appRootURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func hexString(
    from color: Color,
    appearance appearanceName: NSAppearance.Name? = nil
  ) throws -> String {
    guard let appearanceName else {
      return Color.hexString(from: try #require(NSColor(color).usingColorSpace(.sRGB)))
    }

    let appearance = try #require(NSAppearance(named: appearanceName))
    var resolvedColor: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolvedColor = NSColor(color).usingColorSpace(.sRGB)
    }
    return Color.hexString(from: try #require(resolvedColor))
  }
}
