import Foundation
import Testing

@testable import AgentHubCore

@Suite("Theme loading service")
struct ThemeLoadingServiceTests {

  @Test("Discovers valid YAML themes and ignores invalid files")
  func discoversValidYAMLThemes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    try writeTheme(named: "valid.yaml", displayName: "Valid", to: directory)
    try writeTheme(named: "also-valid.yml", displayName: "Also Valid", to: directory)
    try "not: valid: yaml".write(
      to: directory.appendingPathComponent("broken.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try "ignored".write(
      to: directory.appendingPathComponent("notes.txt"),
      atomically: true,
      encoding: .utf8
    )

    let service = ThemeLoadingService()
    let themes = try await service.discoverThemes(in: directory)

    #expect(themes.map(\.id).sorted() == ["also-valid.yml", "valid.yaml"])
    #expect(themes.map(\.name).sorted() == ["Also Valid", "Valid"])
  }

  @Test("Loads a YAML theme with its original palette hex values")
  func loadsThemeWithPaletteHexValues() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = try writeTheme(
      named: "palette.yaml",
      displayName: "Palette",
      primary: "#112233",
      secondary: "#445566",
      tertiary: "#778899",
      to: directory
    )

    let service = ThemeLoadingService()
    let loaded = try await service.loadTheme(fileURL: fileURL)

    #expect(loaded.theme.name == "Palette")
    #expect(loaded.palette == ThemePalette(
      primary: "#112233",
      secondary: "#445566",
      tertiary: "#778899"
    ))
  }

  @Test("Loads appearance-specific YAML palette variants")
  func loadsAppearanceSpecificPaletteVariants() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("adaptive.yaml")
    let yaml = """
    name: "Adaptive"
    version: "1.0"
    colors:
      brand:
        primary: "#112233"
        secondary: "#445566"
        tertiary: "#778899"
        light:
          primary: "#223344"
          secondary: "#556677"
          tertiary: "#8899AA"
        dark:
          primary: "#AABBCC"
          secondary: "#BBCCDD"
          tertiary: "#CCDDEE"
    """
    try yaml.write(to: fileURL, atomically: true, encoding: .utf8)

    let loaded = try await ThemeLoadingService().loadTheme(fileURL: fileURL)

    #expect(loaded.palette.light == ThemePalette.Variant(
      primary: "#223344",
      secondary: "#556677",
      tertiary: "#8899AA"
    ))
    #expect(loaded.palette.dark == ThemePalette.Variant(
      primary: "#AABBCC",
      secondary: "#BBCCDD",
      tertiary: "#CCDDEE"
    ))
  }

  @Test("Persisting a plain palette clears stale appearance variants")
  func persistingPlainPaletteClearsStaleAppearanceVariants() async throws {
    let suiteName = "ThemeLoadingServiceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let writer = ThemePreferenceWriter(defaults: defaults)
    let variant = ThemePalette.Variant(
      primary: "#223344",
      secondary: "#556677",
      tertiary: "#8899AA"
    )

    await writer.persistYAMLPalette(ThemePalette(
      primary: "#112233",
      secondary: "#445566",
      tertiary: "#778899",
      light: variant,
      dark: variant
    ))
    await writer.persistYAMLPalette(ThemePalette(
      primary: "#AABBCC",
      secondary: "#BBCCDD",
      tertiary: "#CCDDEE"
    ))

    #expect(defaults.string(forKey: AgentHubDefaults.yamlPrimaryHex) == "#AABBCC")
    #expect(defaults.string(forKey: AgentHubDefaults.yamlLightPrimaryHex) == nil)
    #expect(defaults.string(forKey: AgentHubDefaults.yamlLightSecondaryHex) == nil)
    #expect(defaults.string(forKey: AgentHubDefaults.yamlLightTertiaryHex) == nil)
    #expect(defaults.string(forKey: AgentHubDefaults.yamlDarkPrimaryHex) == nil)
    #expect(defaults.string(forKey: AgentHubDefaults.yamlDarkSecondaryHex) == nil)
    #expect(defaults.string(forKey: AgentHubDefaults.yamlDarkTertiaryHex) == nil)
  }

  @discardableResult
  private func writeTheme(
    named fileName: String,
    displayName: String,
    primary: String = "#112233",
    secondary: String = "#445566",
    tertiary: String = "#778899",
    to directory: URL
  ) throws -> URL {
    let fileURL = directory.appendingPathComponent(fileName)
    let yaml = """
    name: "\(displayName)"
    version: "1.0"
    description: "\(displayName) theme"
    colors:
      brand:
        primary: "\(primary)"
        secondary: "\(secondary)"
        tertiary: "\(tertiary)"
    """
    try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ThemeLoadingServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
