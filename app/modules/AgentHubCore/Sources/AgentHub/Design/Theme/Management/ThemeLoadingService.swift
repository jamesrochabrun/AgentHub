//
//  ThemeLoadingService.swift
//  AgentHub
//

import Foundation

struct ThemePalette: Equatable, Sendable {
  let primary: String
  let secondary: String
  let tertiary: String
}

struct DiscoveredYAMLTheme: Equatable, Sendable {
  let id: String
  let name: String
  let description: String?
  let fileURL: URL
}

struct LoadedYAMLTheme: Sendable {
  let theme: YAMLTheme
  let palette: ThemePalette
}

protocol ThemeLoadingServiceProtocol: Sendable {
  func discoverThemes(in themesDirectory: URL) async throws -> [DiscoveredYAMLTheme]
  func loadTheme(fileURL: URL) async throws -> LoadedYAMLTheme
}

protocol ThemePreferenceWriting: Sendable {
  func persistYAMLPalette(_ palette: ThemePalette) async
  func persistThemeSelection(_ themeId: String, backend: EmbeddedTerminalBackend) async
}

actor ThemeLoadingService: ThemeLoadingServiceProtocol {
  private let parser = YAMLThemeParser()
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func discoverThemes(in themesDirectory: URL) async throws -> [DiscoveredYAMLTheme] {
    guard fileManager.fileExists(atPath: themesDirectory.path) else {
      try fileManager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
      return []
    }

    let files = try fileManager.contentsOfDirectory(
      at: themesDirectory,
      includingPropertiesForKeys: [.nameKey],
      options: [.skipsHiddenFiles]
    )

    return files
      .filter(Self.isYAMLFile)
      .compactMap { fileURL in
        guard let loaded = try? loadThemeSynchronously(fileURL: fileURL) else {
          return nil
        }
        return DiscoveredYAMLTheme(
          id: fileURL.lastPathComponent,
          name: loaded.theme.name,
          description: loaded.theme.description,
          fileURL: fileURL
        )
      }
  }

  func loadTheme(fileURL: URL) async throws -> LoadedYAMLTheme {
    try loadThemeSynchronously(fileURL: fileURL)
  }

  private func loadThemeSynchronously(fileURL: URL) throws -> LoadedYAMLTheme {
    let theme = try parser.parse(fileURL: fileURL)
    return LoadedYAMLTheme(
      theme: theme,
      palette: ThemePalette(
        primary: theme.colors.brand.primary,
        secondary: theme.colors.brand.secondary,
        tertiary: theme.colors.brand.tertiary
      )
    )
  }

  private nonisolated static func isYAMLFile(_ fileURL: URL) -> Bool {
    fileURL.pathExtension == "yaml" || fileURL.pathExtension == "yml"
  }
}

actor ThemePreferenceWriter: ThemePreferenceWriting {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func persistYAMLPalette(_ palette: ThemePalette) async {
    defaults.set(palette.primary, forKey: AgentHubDefaults.yamlPrimaryHex)
    defaults.set(palette.secondary, forKey: AgentHubDefaults.yamlSecondaryHex)
    defaults.set(palette.tertiary, forKey: AgentHubDefaults.yamlTertiaryHex)
  }

  func persistThemeSelection(_ themeId: String, backend: EmbeddedTerminalBackend) async {
    ThemeSelectionPolicy.persistThemeSelection(themeId, defaults: defaults, backend: backend)
  }
}
