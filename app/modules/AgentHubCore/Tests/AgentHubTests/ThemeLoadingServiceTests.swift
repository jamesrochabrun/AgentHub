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
