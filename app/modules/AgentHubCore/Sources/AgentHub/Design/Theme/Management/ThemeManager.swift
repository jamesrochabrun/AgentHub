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

  @ObservationIgnored private let loadingService: any ThemeLoadingServiceProtocol
  @ObservationIgnored private let preferenceWriter: any ThemePreferenceWriting
  @ObservationIgnored private let fileWatcher: any ThemeFileWatching
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let themesDirectoryURL: URL
  @ObservationIgnored private var themeCache: [String: RuntimeTheme] = [:]
  @ObservationIgnored private var yamlColorCache: [String: ThemePalette] = [:]
  @ObservationIgnored private var activeWatchedThemeURL: URL?
  @ObservationIgnored private var selectionGeneration = 0

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

  private static let bundledHeliosYAML = """
  name: "Helios"
  version: "1.0"
  author: "AgentHub"
  description: "Warm amber and gold theme inspired by the Greek sun god — sunlight piercing the void"

  colors:
    brand:
      primary: "#F59E0B"
      secondary: "#78350F"
      tertiary: "#FCD34D"

    backgrounds:
      dark: "#1A1410"
      expandedContentDark: "#140E0A"
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

  private static let bundledGhosttyYAML = """
  name: "Ghostty"
  version: "1.2"
  author: "AgentHub"
  description: "Ghostty-only theme with Singularity highlights and soft app backgrounds"

  colors:
    brand:
      primary: "#A0AEC0"
      secondary: "#2D3748"
      tertiary: "#CBD5E0"

    backgrounds:
      dark: "#040F16"
      light: "#FBFBFF"

    terminal:
      background: "#040F16"
      foreground: "#E2E8F0"
      cursor: "#A0AEC0"
      ansi:
        black: "#0D0D0D"
        red: "#E06C75"
        green: "#98C379"
        yellow: "#ECC94B"
        blue: "#61AFEF"
        magenta: "#C678DD"
        cyan: "#56B6C2"
        white: "#E2E8F0"
        brightBlack: "#718096"
        brightRed: "#E88A91"
        brightGreen: "#B5D4A1"
        brightYellow: "#F6E05E"
        brightBlue: "#8CC8F5"
        brightMagenta: "#D8A0E8"
        brightCyan: "#7DCBD5"
        brightWhite: "#F7FAFC"
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

  public struct ThemeMetadata: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let fileURL: URL?
    public let isYAML: Bool
  }

  public convenience init() {
    let defaults = UserDefaults.standard
    self.init(
      defaults: defaults,
      themesDirectory: Self.themesDirectory(),
      loadingService: ThemeLoadingService(),
      preferenceWriter: ThemePreferenceWriter(defaults: defaults),
      fileWatcher: ThemeFileWatcher(),
      installBundledThemes: true,
      loadSavedThemeAsync: true
    )
  }

  init(
    defaults: UserDefaults,
    themesDirectory: URL,
    loadingService: any ThemeLoadingServiceProtocol,
    preferenceWriter: (any ThemePreferenceWriting)? = nil,
    fileWatcher: any ThemeFileWatching,
    installBundledThemes: Bool,
    loadSavedThemeAsync: Bool
  ) {
    self.defaults = defaults
    self.themesDirectoryURL = themesDirectory
    self.loadingService = loadingService
    self.preferenceWriter = preferenceWriter ?? ThemePreferenceWriter(defaults: defaults)
    self.fileWatcher = fileWatcher

    // Load the correct built-in theme synchronously to avoid flash on launch.
    // Preference writes happen later through ThemePreferenceWriter so launch does not block on defaults KVO.
    let backend = EmbeddedTerminalBackend.storedPreference(in: defaults)
    let saved = ThemeSelectionPolicy.resolvedPersistedThemeSelection(defaults: defaults, backend: backend)
    if let appTheme = AppTheme(rawValue: saved) {
      self.currentTheme = Self.loadBuiltInTheme(appTheme)
    } else {
      // YAML theme — start with neutral sync, async load replaces it
      self.currentTheme = Self.loadBuiltInTheme(.neutral)
    }
    if installBundledThemes {
      self.installBundledThemesIfNeeded()
    }

    // Schedule async loading for YAML themes (including the default)
    if loadSavedThemeAsync, AppTheme(rawValue: saved) == nil {
      Task { await self.loadSavedTheme() }
    }
  }

  // MARK: - Theme Discovery

  public func discoverThemes() async {
    do {
      let discoveredThemes = try await loadingService.discoverThemes(in: themesDirectoryURL)
      self.availableYAMLThemes = discoveredThemes.map(Self.metadata(from:))
    } catch {
      AppLogger.session.error("Failed to discover themes: \(error.localizedDescription)")
    }
  }

  // MARK: - Theme Loading

  public func loadTheme(fileURL: URL) async throws {
    let backend = EmbeddedTerminalBackend.storedPreference(in: defaults)
    let generation = beginThemeSelection()
    try await loadTheme(
      fileURL: fileURL,
      backend: backend,
      generation: generation,
      forceReload: false
    )
  }

  @discardableResult
  public func applySelection(_ requestedSelection: String, backend: EmbeddedTerminalBackend) async -> String {
    let defaultThemeId = ThemeSelectionPolicy.defaultThemeId(for: backend)
    let selection = ThemeSelectionPolicy.canonicalThemeId(
      for: requestedSelection,
      backend: backend
    ) ?? defaultThemeId

    if backend == .regular, let appTheme = AppTheme(rawValue: selection) {
      if isCurrentBuiltInTheme(appTheme),
         isPersistedThemeSelection(appTheme.rawValue, backend: backend) {
        beginThemeSelection()
        return appTheme.rawValue
      }

      beginThemeSelection()
      await applyBuiltInTheme(appTheme, persistedThemeId: appTheme.rawValue, backend: backend)
      return appTheme.rawValue
    }

    let fileId = ThemeSelectionPolicy.matchingBundledYAMLFileId(
      for: selection,
      in: ThemeSelectionPolicy.bundledYAMLThemeFileIds(for: backend)
    ) ?? selection

    if isCurrentYAMLTheme(fileId),
       isPersistedThemeSelection(fileId, backend: backend) {
      beginThemeSelection()
      return fileId
    }

    let generation = beginThemeSelection()
    let themeURL = themesDirectoryURL.appendingPathComponent(fileId)
    do {
      try await loadTheme(
        fileURL: themeURL,
        backend: backend,
        generation: generation,
        forceReload: false
      )
      return fileId
    } catch {
      AppLogger.session.error("Failed to apply theme \(fileId): \(error.localizedDescription)")
      guard isCurrentGeneration(generation) else { return fileId }
      await applyBuiltInTheme(.neutral, persistedThemeId: defaultThemeId, backend: backend)
      return defaultThemeId
    }
  }

  private func loadTheme(
    fileURL: URL,
    backend: EmbeddedTerminalBackend,
    generation: Int,
    forceReload: Bool
  ) async throws {
    let cacheKey = fileURL.lastPathComponent
    if !forceReload, let cached = themeCache[cacheKey] {
      guard isCurrentGeneration(generation) else { return }
      stopWatchingInactiveThemeFile(nextThemeURL: fileURL)
      self.currentTheme = cached
      setupHotReload(for: fileURL)
      await persistYAMLPalette(for: cacheKey)
      await saveCurrentThemeSelection(cacheKey, backend: backend)
      return
    }

    let loaded = try await loadingService.loadTheme(fileURL: fileURL)
    guard isCurrentGeneration(generation) else { return }

    stopWatchingInactiveThemeFile(nextThemeURL: fileURL)
    let runtime = RuntimeTheme(from: loaded.theme, sourceFileName: cacheKey)
    themeCache[cacheKey] = runtime
    yamlColorCache[cacheKey] = loaded.palette
    self.currentTheme = runtime

    // Setup hot-reload
    setupHotReload(for: fileURL)
    await persistYAMLPalette(for: cacheKey)
    await saveCurrentThemeSelection(cacheKey, backend: backend)
  }

  public func loadBuiltInTheme(_ theme: AppTheme) {
    beginThemeSelection()
    let backend = EmbeddedTerminalBackend.storedPreference(in: defaults)
    applyBuiltInThemeAndPersistLater(theme, persistedThemeId: theme.rawValue, backend: backend)
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
          let generation = self.selectionGeneration
          let backend = EmbeddedTerminalBackend.storedPreference(in: self.defaults)
          self.themeCache.removeValue(forKey: cacheKey)
          try await self.loadTheme(
            fileURL: fileURL,
            backend: backend,
            generation: generation,
            forceReload: true
          )
          AppLogger.session.info("Hot-reloaded theme: \(fileURL.lastPathComponent)")
        } catch {
          AppLogger.session.error("Failed to hot-reload theme: \(error.localizedDescription)")
        }
      }
    }
    activeWatchedThemeURL = fileURL
  }

  // MARK: - Persistence

  private func saveCurrentThemeSelection(
    _ themeId: String,
    backend: EmbeddedTerminalBackend
  ) async {
    await preferenceWriter.persistThemeSelection(themeId, backend: backend)
  }

  public func loadSavedTheme() async {
    let backend = EmbeddedTerminalBackend.storedPreference(in: defaults)
    let saved = ThemeSelectionPolicy.resolvedPersistedThemeSelection(defaults: defaults, backend: backend)
    await applySelection(saved, backend: backend)
  }

  // MARK: - Utilities

  public static func themesDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("AgentHub/Themes")
  }

  public func openThemesFolder() {
    let url = themesDirectoryURL
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    NSWorkspace.shared.open(url)
  }

  // MARK: - Internal Helpers

  private static func metadata(from discoveredTheme: DiscoveredYAMLTheme) -> ThemeMetadata {
    ThemeMetadata(
      id: discoveredTheme.id,
      name: discoveredTheme.name,
      description: discoveredTheme.description,
      fileURL: discoveredTheme.fileURL,
      isYAML: true
    )
  }

  @discardableResult
  private func beginThemeSelection() -> Int {
    selectionGeneration += 1
    return selectionGeneration
  }

  private func isCurrentGeneration(_ generation: Int) -> Bool {
    selectionGeneration == generation
  }

  private func isCurrentBuiltInTheme(_ theme: AppTheme) -> Bool {
    currentTheme.isBuiltIn && currentTheme.id == theme.rawValue
  }

  private func isCurrentYAMLTheme(_ fileId: String) -> Bool {
    currentTheme.isYAML && currentTheme.sourceFileName == fileId
  }

  private func isPersistedThemeSelection(_ themeId: String, backend: EmbeddedTerminalBackend) -> Bool {
    guard let persistedThemeId = defaults.string(forKey: AgentHubDefaults.selectedTheme) else {
      return false
    }
    return ThemeSelectionPolicy.canonicalThemeId(for: persistedThemeId, backend: backend) == themeId
  }

  private func applyBuiltInTheme(
    _ theme: AppTheme,
    persistedThemeId: String,
    backend: EmbeddedTerminalBackend
  ) async {
    stopWatchingInactiveThemeFile(nextThemeURL: nil)
    let runtime = Self.loadBuiltInTheme(theme)
    self.currentTheme = runtime
    await saveCurrentThemeSelection(persistedThemeId, backend: backend)
  }

  private func applyBuiltInThemeAndPersistLater(
    _ theme: AppTheme,
    persistedThemeId: String,
    backend: EmbeddedTerminalBackend
  ) {
    stopWatchingInactiveThemeFile(nextThemeURL: nil)
    let runtime = Self.loadBuiltInTheme(theme)
    self.currentTheme = runtime
    let preferenceWriter = preferenceWriter
    Task.detached(priority: .utility) {
      await preferenceWriter.persistThemeSelection(persistedThemeId, backend: backend)
    }
  }

  private func stopWatchingInactiveThemeFile(nextThemeURL: URL?) {
    guard activeWatchedThemeURL != nextThemeURL else { return }
    if let activeWatchedThemeURL {
      fileWatcher.stopWatching(fileURL: activeWatchedThemeURL)
      self.activeWatchedThemeURL = nil
    }
  }

  private static let bundledThemes: [(name: String, fallbackYAML: String)] = [
    ("sentry", bundledSentryYAML),
    ("rigel", bundledRigelYAML),
    ("vela", bundledVelaYAML),
    ("antares", bundledAntaresYAML),
    ("singularity", bundledSingularityYAML),
    ("ghostty", bundledGhosttyYAML),
    ("nebula", bundledNebulaYAML),
    ("helios", bundledHeliosYAML),
  ]

  private func installBundledThemesIfNeeded() {
    let themesDir = themesDirectoryURL
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

  private func persistYAMLPalette(for cacheKey: String) async {
    guard let colors = yamlColorCache[cacheKey] else { return }
    await preferenceWriter.persistYAMLPalette(colors)
  }
}
