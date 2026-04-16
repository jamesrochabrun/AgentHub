//
//  ThemeManager.swift
//  AgentHub
//
//  Centralized theme management with discovery, loading, caching, and hot-reload
//

import Foundation
import SwiftUI
import AppKit
import os

@MainActor
@Observable
public final class ThemeManager {
  public private(set) var currentTheme: RuntimeTheme
  public private(set) var availableYAMLThemes: [ThemeMetadata] = []

  @ObservationIgnored private let parser = YAMLThemeParser()
  @ObservationIgnored private let fileWatcher: ThemeFileWatcher
  @ObservationIgnored private var themeCache: [String: RuntimeTheme] = [:]
  @ObservationIgnored private var yamlColorCache: [String: (primary: String, secondary: String, tertiary: String)] = [:]
  @ObservationIgnored private var activeWatchedThemeURL: URL?

  private static let bundledSentryYAML = """
  name: "Sentry"
  version: "1.0"
  author: "Sentry"
  description: "Official Sentry-inspired color theme"

  colors:
    brand:
      primary: "#E1567C"
      secondary: "#362D59"
      tertiary: "#584774"

    backgrounds:
      dark: "#1A1625"
  """

  private static let bundledRauschYAML = """
  name: "Rausch"
  version: "1.0"
  author: "AgentHub"
  description: "Warm coral accent theme inspired by the Rausch color palette"

  colors:
    brand:
      primary: "#FF385C"
      secondary: "#E31C5F"
      tertiary: "#D70466"

    backgrounds:
      dark: "#222222"
      light: "#FFFFFF"
  """

  private static let bundledNebulaYAML = """
  name: "Nebula"
  version: "1.0"
  author: "AgentHub"
  description: "Matte black theme with violet accents inspired by the ultraviolet glow of cosmic nebulae"

  colors:
    brand:
      primary: "#A78BFA"
      secondary: "#312E81"
      tertiary: "#C4B5FD"

    backgrounds:
      dark: "#0D0D0D"
      expandedContentDark: "#080808"
  """

  private static let bundledSingularityYAML = """
  name: "Singularity"
  version: "1.0"
  author: "AgentHub"
  description: "Matte black theme inspired by the infinite depth of a black hole's singularity"

  colors:
    brand:
      primary: "#A0AEC0"
      secondary: "#2D3748"
      tertiary: "#CBD5E0"

    backgrounds:
      dark: "#0D0D0D"
      expandedContentDark: "#080808"
  """

  private static let bundledAntaresYAML = """
  name: "Antares"
  version: "1.0"
  author: "AgentHub"
  description: "Warm rose-pink theme inspired by the red supergiant Antares — the heart of Scorpius"

  colors:
    brand:
      primary: "#FF6B8A"
      secondary: "#6B2A50"
      tertiary: "#FFB3C1"

    backgrounds:
      dark: "#1F1018"
      expandedContentDark: "#1A0C14"
  """

  private static let bundledVelaYAML = """
  name: "Vela"
  version: "1.0"
  author: "AgentHub"
  description: "Deep forest green theme inspired by the Vela Pulsar's emerald supernova remnant"

  colors:
    brand:
      primary: "#34D399"
      secondary: "#134E3A"
      tertiary: "#6EE7B7"

    backgrounds:
      dark: "#0A1A14"
      expandedContentDark: "#071510"
  """

  private static let bundledRigelYAML = """
  name: "Rigel"
  version: "1.0"
  author: "AgentHub"
  description: "Deep space navy with electric blue accents, inspired by the blue supergiant Rigel"

  colors:
    brand:
      primary: "#38BDF8"
      secondary: "#164E6A"
      tertiary: "#7DD3FC"

    backgrounds:
      dark: "#0A1628"
      expandedContentDark: "#081220"
  """

  private static let bundledBetelgeuseYAML = """
  name: "Betelgeuse"
  version: "1.0"
  author: "AgentHub"
  description: "Warm orange gradient inspired by the red supergiant"

  colors:
    brand:
      primary: "#FF6B22"
      secondary: "#FF8C42"
      tertiary: "#FFB574"

    backgroundGradient:
      - color: "#FF6B22"
        opacity: 0.44
      - color: "#FF8C42"
        opacity: 0.25
  """

  public struct ThemeMetadata: Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let fileURL: URL?
    public let isYAML: Bool
  }

  public init() {
    // Load the correct built-in theme synchronously to avoid flash on launch
    let saved = UserDefaults.standard.string(forKey: AgentHubDefaults.selectedTheme) ?? "singularity.yaml"
    if let appTheme = AppTheme(rawValue: saved) {
      self.currentTheme = Self.loadBuiltInTheme(appTheme)
    } else {
      // YAML theme — start with neutral sync, async load replaces it
      self.currentTheme = Self.loadBuiltInTheme(.neutral)
    }
    self.fileWatcher = ThemeFileWatcher()
    self.installBundledThemesIfNeeded()

    // Schedule async loading for YAML themes (including the default)
    if AppTheme(rawValue: saved) == nil {
      Task { await self.loadSavedTheme() }
    }
  }

  // MARK: - Theme Discovery

  public func discoverThemes() async {
    let themesDir = Self.themesDirectory()

    guard FileManager.default.fileExists(atPath: themesDir.path) else {
      try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
      return
    }

    do {
      let files = try FileManager.default.contentsOfDirectory(
        at: themesDir,
        includingPropertiesForKeys: [.nameKey],
        options: [.skipsHiddenFiles]
      )

      let yamlFiles = files.filter { $0.pathExtension == "yaml" || $0.pathExtension == "yml" }

      var metadata: [ThemeMetadata] = []
      for file in yamlFiles {
        if let theme = try? parser.parse(fileURL: file) {
          metadata.append(ThemeMetadata(
            id: file.lastPathComponent,
            name: theme.name,
            description: theme.description,
            fileURL: file,
            isYAML: true
          ))
        }
      }

      self.availableYAMLThemes = metadata
    } catch {
      AppLogger.session.error("Failed to discover themes: \(error.localizedDescription)")
    }
  }

  // MARK: - Theme Loading

  public func loadTheme(fileURL: URL) async throws {
    stopWatchingInactiveThemeFile(nextThemeURL: fileURL)

    // Check cache first
    let cacheKey = fileURL.lastPathComponent
    if let cached = themeCache[cacheKey] {
      self.currentTheme = cached
      persistYAMLPalette(for: cacheKey, runtime: cached)
      saveCurrentThemeSelection(cacheKey)
      setupHotReload(for: fileURL)
      return
    }

    // Parse and cache
    let yaml = try parser.parse(fileURL: fileURL)
    let runtime = RuntimeTheme(from: yaml, sourceFileName: cacheKey)
    themeCache[cacheKey] = runtime
    yamlColorCache[cacheKey] = (
      primary: yaml.colors.brand.primary,
      secondary: yaml.colors.brand.secondary,
      tertiary: yaml.colors.brand.tertiary
    )
    self.currentTheme = runtime
    persistYAMLPalette(for: cacheKey, runtime: runtime)
    saveCurrentThemeSelection(cacheKey)

    // Setup hot-reload
    setupHotReload(for: fileURL)
  }

  public func loadBuiltInTheme(_ theme: AppTheme) {
    stopWatchingInactiveThemeFile(nextThemeURL: nil)
    let runtime = Self.loadBuiltInTheme(theme)
    self.currentTheme = runtime
    saveCurrentThemeSelection(theme.rawValue)
  }

  private static func loadBuiltInTheme(_ theme: AppTheme) -> RuntimeTheme {
    let colors = getThemeColors(for: theme)
    return RuntimeTheme(appTheme: theme, colors: colors)
  }

  /// Single source of truth for built-in theme colors
  nonisolated static func getThemeColors(for theme: AppTheme) -> ThemeColors {
    switch theme {
    case .neutral:
      return ThemeColors(
        brandPrimary: Color.primary,
        brandSecondary: Color.secondary,
        brandTertiary: Color(nsColor: .tertiaryLabelColor)
      )
    case .claude:
      return ThemeColors(
        brandPrimary: Color(hex: "#CC785C"),
        brandSecondary: Color(hex: "#D4A27F"),
        brandTertiary: Color(hex: "#EBDBBC")
      )
    case .codex:
      return ThemeColors(
        brandPrimary: Color(hex: "#00A5B2"),
        brandSecondary: Color(hex: "#00A5B2"),
        brandTertiary: Color(hex: "#00A5B2")
      )
    case .xcode:
      return ThemeColors(
        brandPrimary: Color(nsColor: .systemBlue),
        brandSecondary: Color(nsColor: .systemIndigo),
        brandTertiary: Color(nsColor: .systemTeal)
      )
    case .custom:
      let primary = UserDefaults.standard.string(forKey: AgentHubDefaults.customPrimaryHex) ?? "#7C3AED"
      let secondary = UserDefaults.standard.string(forKey: AgentHubDefaults.customSecondaryHex) ?? "#FFB000"
      let tertiary = UserDefaults.standard.string(forKey: AgentHubDefaults.customTertiaryHex) ?? "#64748B"
      return ThemeColors(
        brandPrimary: Color(hex: primary),
        brandSecondary: Color(hex: secondary),
        brandTertiary: Color(hex: tertiary)
      )
    }
  }

  // MARK: - Hot Reload

  private func setupHotReload(for fileURL: URL) {
    stopWatchingInactiveThemeFile(nextThemeURL: fileURL)

    fileWatcher.watch(fileURL: fileURL) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        do {
          // Invalidate cache and reload
          let cacheKey = fileURL.lastPathComponent
          self.themeCache.removeValue(forKey: cacheKey)
          try await self.loadTheme(fileURL: fileURL)
          AppLogger.session.info("Hot-reloaded theme: \(fileURL.lastPathComponent)")
        } catch {
          AppLogger.session.error("Failed to hot-reload theme: \(error.localizedDescription)")
        }
      }
    }
    activeWatchedThemeURL = fileURL
  }

  // MARK: - Persistence

  private func saveCurrentThemeSelection(_ themeId: String) {
    UserDefaults.standard.set(themeId, forKey: AgentHubDefaults.selectedTheme)
  }

  public func loadSavedTheme() async {
    let saved = UserDefaults.standard.string(forKey: AgentHubDefaults.selectedTheme) ?? "singularity.yaml"

    // Check if it's a built-in theme
    if let appTheme = AppTheme(rawValue: saved) {
      loadBuiltInTheme(appTheme)
      return
    }

    // Check if it's a YAML theme
    let themesDir = Self.themesDirectory()
    let fileURL = themesDir.appendingPathComponent(saved)

    if FileManager.default.fileExists(atPath: fileURL.path) {
      try? await loadTheme(fileURL: fileURL)
    } else {
      // Fallback: try singularity, then neutral
      let fallbackURL = themesDir.appendingPathComponent("singularity.yaml")
      if FileManager.default.fileExists(atPath: fallbackURL.path) {
        try? await loadTheme(fileURL: fallbackURL)
      } else {
        loadBuiltInTheme(.neutral)
      }
    }
  }

  // MARK: - Utilities

  public static func themesDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("AgentHub/Themes")
  }

  public func openThemesFolder() {
    let url = Self.themesDirectory()
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }

  // MARK: - Internal Helpers

  private func stopWatchingInactiveThemeFile(nextThemeURL: URL?) {
    guard activeWatchedThemeURL != nextThemeURL else { return }
    if let activeWatchedThemeURL {
      fileWatcher.stopWatching(fileURL: activeWatchedThemeURL)
      self.activeWatchedThemeURL = nil
    }
  }

  private static let bundledThemes: [(name: String, fallbackYAML: String)] = [
    ("betelgeuse", bundledBetelgeuseYAML),
    ("sentry", bundledSentryYAML),
    ("rausch", bundledRauschYAML),
    ("rigel", bundledRigelYAML),
    ("vela", bundledVelaYAML),
    ("antares", bundledAntaresYAML),
    ("singularity", bundledSingularityYAML),
    ("nebula", bundledNebulaYAML),
  ]

  private func installBundledThemesIfNeeded() {
    let themesDir = Self.themesDirectory()
    do {
      try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
    } catch {
      AppLogger.session.error("Failed to create themes directory: \(error.localizedDescription)")
      return
    }

    for (themeName, fallbackYAML) in Self.bundledThemes {
      installBundledTheme(name: themeName, fallbackYAML: fallbackYAML, themesDir: themesDir)
    }
  }

  private func installBundledTheme(name: String, fallbackYAML: String, themesDir: URL) {
    // Resolve bundled content
    let bundledContent: String
    if let bundledURL = Self.bundledThemeURL(name: name),
       let data = try? String(contentsOf: bundledURL, encoding: .utf8) {
      bundledContent = data
    } else {
      bundledContent = fallbackYAML
    }

    // Parse bundled version
    let bundledVersion = bundledContent
      .components(separatedBy: .newlines)
      .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("version:") })
      .flatMap { line -> String? in
        let value = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      }

    let defaults = UserDefaults.standard
    let versionKey = AgentHubDefaults.installedBundledThemeVersion(for: name)
    let installedVersion = defaults.string(forKey: versionKey)
    let destinationURL = themesDir.appendingPathComponent("\(name).yaml")
    let fileExists = FileManager.default.fileExists(atPath: destinationURL.path)

    // Skip if file exists and versions match
    if fileExists, let bundledVersion, installedVersion == bundledVersion {
      return
    }

    do {
      try bundledContent.write(to: destinationURL, atomically: true, encoding: .utf8)
      if let bundledVersion {
        defaults.set(bundledVersion, forKey: versionKey)
      }
    } catch {
      AppLogger.session.error("Failed to install bundled \(name).yaml: \(error.localizedDescription)")
    }
  }

  private static func bundledThemeURL(name: String) -> URL? {
    let candidates: [URL?] = [
      Bundle.module.url(
        forResource: name,
        withExtension: "yaml",
        subdirectory: "Design/Theme/BundledThemes"
      ),
      Bundle.module.url(
        forResource: name,
        withExtension: "yaml",
        subdirectory: "BundledThemes"
      ),
      Bundle.module.url(forResource: name, withExtension: "yaml"),
    ]

    if let candidate = candidates.compactMap({ $0 }).first {
      return candidate
    }

    return Bundle.module.urls(forResourcesWithExtension: "yaml", subdirectory: nil)?
      .first(where: { $0.lastPathComponent == "\(name).yaml" })
  }

  private func persistYAMLPalette(for cacheKey: String, runtime: RuntimeTheme) {
    let defaults = UserDefaults.standard
    if let colors = yamlColorCache[cacheKey] {
      defaults.set(colors.primary, forKey: AgentHubDefaults.yamlPrimaryHex)
      defaults.set(colors.secondary, forKey: AgentHubDefaults.yamlSecondaryHex)
      defaults.set(colors.tertiary, forKey: AgentHubDefaults.yamlTertiaryHex)
      return
    }

    // Fallback when serving from runtime-only cache.
    if let primary = Self.hexString(from: runtime.brandPrimary) {
      defaults.set(primary, forKey: AgentHubDefaults.yamlPrimaryHex)
    }
    if let secondary = Self.hexString(from: runtime.brandSecondary) {
      defaults.set(secondary, forKey: AgentHubDefaults.yamlSecondaryHex)
    }
    if let tertiary = Self.hexString(from: runtime.brandTertiary) {
      defaults.set(tertiary, forKey: AgentHubDefaults.yamlTertiaryHex)
    }
  }

  private static func hexString(from color: Color) -> String? {
    guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    var red: CGFloat = .zero
    var green: CGFloat = .zero
    var blue: CGFloat = .zero
    var alpha: CGFloat = .zero
    resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
  }
}
