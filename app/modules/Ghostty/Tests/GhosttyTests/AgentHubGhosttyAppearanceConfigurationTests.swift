import Foundation
import GhosttySwift
import Testing
@testable import Ghostty

@Suite("AgentHub Ghostty appearance configuration")
struct AgentHubGhosttyAppearanceConfigurationTests {
  @Test("Light appearance uses a high-contrast foreground and ANSI white")
  func lightAppearanceUsesReadableColors() throws {
    let path = try #require(
      AgentHubGhosttyAppearanceConfiguration.path(isDark: false)
    )
    let contents = try String(contentsOfFile: path, encoding: .utf8)

    #expect(contents.contains("background = #FBFBFF"))
    #expect(contents.contains("foreground = #2D3748"))
    #expect(contents.contains("palette = 15=#2D3748"))
    // minimum-contrast must never be set in the light profile: with
    // background-opacity 0, Ghostty computes contrast against transparent
    // black and flips dark text to white, making light mode illegible.
    let activeLines = contents
      .split(separator: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    #expect(!activeLines.contains { $0.contains("minimum-contrast") })
    #expect(contents.contains("background-opacity = 0"))
  }

  @Test("Dark appearance preserves the Ghostty palette")
  func darkAppearanceUsesGhosttyColors() throws {
    let path = try #require(
      AgentHubGhosttyAppearanceConfiguration.path(isDark: true)
    )
    let contents = try String(contentsOfFile: path, encoding: .utf8)

    #expect(contents.contains("background = #252627"))
    #expect(contents.contains("foreground = #E2E8F0"))
    #expect(contents.contains("palette = 15=#F7FAFC"))
    #expect(contents.contains("minimum-contrast = 4.5"))
  }

  @Test("System appearance maps to Ghostty's native color scheme")
  func appearanceMapsToNativeColorScheme() {
    #expect(AgentHubGhosttyAppearanceConfiguration.colorScheme(isDark: false) == .light)
    #expect(AgentHubGhosttyAppearanceConfiguration.colorScheme(isDark: true) == .dark)
  }

  @Test("Backdrop hex rewrites background and cursor-text, nothing else")
  func backdropHexRewritesOnlyBackgroundKeys() throws {
    let bundledPath = try #require(AgentHubGhosttyAppearanceConfiguration.path(isDark: false))
    let base = try String(contentsOfFile: bundledPath, encoding: .utf8)

    let content = AgentHubGhosttyAppearanceConfiguration.overlayContent(
      base: base,
      backdropHex: "#FBF1C7"
    )

    #expect(content.contains("background = #FBF1C7"))
    #expect(content.contains("cursor-text = #FBF1C7"))
    #expect(!content.contains("background = #FBFBFF"))
    // Everything else passes through untouched — especially the transparent
    // opacity that lets the app paint the backdrop, and the palette.
    #expect(content.contains("background-opacity = 0"))
    #expect(content.contains("foreground = #2D3748"))
    #expect(content.contains("selection-background = #CBD5E0"))
    #expect(content.contains("palette = 15=#2D3748"))
  }

  @Test("Rewrite leaves comment lines and the dark contrast guard intact")
  func backdropHexPreservesCommentsAndContrast() throws {
    let bundledPath = try #require(AgentHubGhosttyAppearanceConfiguration.path(isDark: true))
    let base = try String(contentsOfFile: bundledPath, encoding: .utf8)

    let content = AgentHubGhosttyAppearanceConfiguration.overlayContent(
      base: base,
      backdropHex: "#1D2021"
    )

    #expect(content.contains("background = #1D2021"))
    #expect(content.contains("minimum-contrast = 4.5"))
    let originalComments = base.components(separatedBy: "\n")
      .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    for comment in originalComments {
      #expect(content.contains(comment))
    }
  }

  @Test("Generated overlay is written once and reused")
  func generatedOverlayPathIsStable() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-appearance-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try #require(
      AgentHubGhosttyAppearanceConfiguration.path(
        isDark: false,
        backdropHex: "#FBF1C7",
        directory: directory
      )
    )
    let second = try #require(
      AgentHubGhosttyAppearanceConfiguration.path(
        isDark: false,
        backdropHex: "#FBF1C7",
        directory: directory
      )
    )

    #expect(first == second)
    #expect(first != AgentHubGhosttyAppearanceConfiguration.path(isDark: false))
    let contents = try String(contentsOfFile: first, encoding: .utf8)
    #expect(contents.contains("background = #FBF1C7"))
    #expect(contents.contains("background-opacity = 0"))
  }

  @Test("Distinct appearances and hexes generate distinct overlays")
  func distinctInputsGenerateDistinctOverlays() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-appearance-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let lightYellow = AgentHubGhosttyAppearanceConfiguration.path(
      isDark: false, backdropHex: "#FBF1C7", directory: directory
    )
    let lightWhite = AgentHubGhosttyAppearanceConfiguration.path(
      isDark: false, backdropHex: "#FFFFFF", directory: directory
    )
    let darkYellowHex = AgentHubGhosttyAppearanceConfiguration.path(
      isDark: true, backdropHex: "#FBF1C7", directory: directory
    )

    #expect(lightYellow != lightWhite)
    #expect(lightYellow != darkYellowHex)
  }

  @Test("Missing or invalid backdrop hex falls back to the bundled overlay")
  func invalidBackdropHexFallsBackToBundledOverlay() throws {
    let bundled = AgentHubGhosttyAppearanceConfiguration.path(isDark: false)

    #expect(
      AgentHubGhosttyAppearanceConfiguration.path(isDark: false, backdropHex: nil) == bundled
    )
    #expect(
      AgentHubGhosttyAppearanceConfiguration.path(isDark: false, backdropHex: "not-a-hex")
        == bundled
    )
    #expect(
      AgentHubGhosttyAppearanceConfiguration.path(isDark: false, backdropHex: "#FFF") == bundled
    )
  }

  @Test("User-theme passthrough only sets transparency")
  func passthroughOnlySetsTransparency() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-appearance-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = try #require(
      AgentHubGhosttyAppearanceConfiguration.userThemePassthroughPath(
        backdropHex: "#1D2021",
        directory: directory
      )
    )
    let contents = try String(contentsOfFile: path, encoding: .utf8)

    let activeLines = contents
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    // The user's own config/theme must supply every color: the only active
    // directive is the transparency that lets the app paint the backdrop.
    #expect(activeLines == ["background-opacity = 0"])
  }

  @Test("Passthrough path changes with the adopted background")
  func passthroughPathTracksBackdropHex() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-appearance-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = AgentHubGhosttyAppearanceConfiguration.userThemePassthroughPath(
      backdropHex: "#1D2021", directory: directory
    )
    let sameAgain = AgentHubGhosttyAppearanceConfiguration.userThemePassthroughPath(
      backdropHex: "#1d2021", directory: directory
    )
    let changed = AgentHubGhosttyAppearanceConfiguration.userThemePassthroughPath(
      backdropHex: "#FBF1C7", directory: directory
    )

    // Stable per hex (so libghostty's unchanged-path guard no-ops), but a new
    // adopted background must produce a new path to force a config reload.
    #expect(first == sameAgain)
    #expect(first != changed)
  }

  @Test("Passthrough requires a valid adopted hex")
  func passthroughRequiresValidHex() {
    #expect(
      AgentHubGhosttyAppearanceConfiguration.userThemePassthroughPath(backdropHex: nil) == nil
    )
    #expect(
      AgentHubGhosttyAppearanceConfiguration.userThemePassthroughPath(backdropHex: "oops") == nil
    )
  }

  @Test("Backdrop hex is normalized before naming the overlay")
  func backdropHexIsNormalized() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ghostty-appearance-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let lowercased = AgentHubGhosttyAppearanceConfiguration.path(
      isDark: false, backdropHex: "#fbf1c7", directory: directory
    )
    let uppercased = AgentHubGhosttyAppearanceConfiguration.path(
      isDark: false, backdropHex: "#FBF1C7", directory: directory
    )
    let bare = AgentHubGhosttyAppearanceConfiguration.path(
      isDark: false, backdropHex: "FBF1C7", directory: directory
    )

    #expect(lowercased == uppercased)
    #expect(bare == uppercased)
  }
}
