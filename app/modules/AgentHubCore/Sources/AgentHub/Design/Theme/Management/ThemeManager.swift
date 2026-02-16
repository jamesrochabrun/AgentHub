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
      light: "#FAF9FB"
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
    let saved = UserDefaults.standard.string(forKey: AgentHubDefaults.selectedTheme) ?? "claude"
    if let appTheme = AppTheme(rawValue: saved) {
      self.currentTheme = Self.loadBuiltInTheme(appTheme)
    } else {
      // YAML theme — start with Claude, async load will replace it
      self.currentTheme = Self.loadBuiltInTheme(.claude)
    }
    self.fileWatcher = ThemeFileWatcher()
    self.installBundledThemesIfNeeded()

    // Only schedule async loading for YAML themes
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
    case .bat:
      return ThemeColors(
        brandPrimary: Color(hex: "#7C3AED"),
        brandSecondary: Color(hex: "#FFB000"),
        brandTertiary: Color(hex: "#64748B")
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
    let saved = UserDefaults.standard.string(forKey: AgentHubDefaults.selectedTheme) ?? "claude"

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
      // Fallback to default
      loadBuiltInTheme(.claude)
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

  private func installBundledThemesIfNeeded() {
    let themesDir = Self.themesDirectory()
    do {
      try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
    } catch {
      AppLogger.session.error("Failed to create themes directory: \(error.localizedDescription)")
      return
    }

    // Resolve bundled content
    let bundledContent: String
    if let bundledURL = Self.bundledSentryThemeURL(),
       let data = try? String(contentsOf: bundledURL, encoding: .utf8) {
      bundledContent = data
    } else {
      bundledContent = Self.bundledSentryYAML
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
    let versionKey = AgentHubDefaults.installedBundledThemeVersion(for: "sentry")
    let installedVersion = defaults.string(forKey: versionKey)
    let sentryDestinationURL = themesDir.appendingPathComponent("sentry.yaml")
    let fileExists = FileManager.default.fileExists(atPath: sentryDestinationURL.path)

    // Skip if file exists and versions match
    if fileExists, let bundledVersion, installedVersion == bundledVersion {
      return
    }

    do {
      try bundledContent.write(to: sentryDestinationURL, atomically: true, encoding: .utf8)
      if let bundledVersion {
        defaults.set(bundledVersion, forKey: versionKey)
      }
    } catch {
      AppLogger.session.error("Failed to install bundled sentry.yaml: \(error.localizedDescription)")
    }
  }

  private static func bundledSentryThemeURL() -> URL? {
    let candidates: [URL?] = [
      Bundle.module.url(
        forResource: "sentry",
        withExtension: "yaml",
        subdirectory: "Design/Theme/BundledThemes"
      ),
      Bundle.module.url(
        forResource: "sentry",
        withExtension: "yaml",
        subdirectory: "BundledThemes"
      ),
      Bundle.module.url(forResource: "sentry", withExtension: "yaml"),
    ]

    if let candidate = candidates.compactMap({ $0 }).first {
      return candidate
    }

    return Bundle.module.urls(forResourcesWithExtension: "yaml", subdirectory: nil)?
      .first(where: { $0.lastPathComponent == "sentry.yaml" })
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
