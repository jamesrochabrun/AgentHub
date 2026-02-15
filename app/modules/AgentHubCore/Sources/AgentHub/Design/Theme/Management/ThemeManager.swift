//
//  ThemeManager.swift
//  AgentHub
//
//  Centralized theme management with discovery, loading, caching, and hot-reload
//

import Foundation
import SwiftUI
import os

@MainActor
public final class ThemeManager: ObservableObject {
  @Published public private(set) var currentTheme: RuntimeTheme
  @Published public private(set) var availableYAMLThemes: [ThemeMetadata] = []

  private let parser = YAMLThemeParser()
  private let fileWatcher: ThemeFileWatcher
  private var themeCache: [String: RuntimeTheme] = [:]

  public struct ThemeMetadata: Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let fileURL: URL?
    public let isYAML: Bool
  }

  public init() {
    // Start with default theme (from current UserDefaults)
    let defaultTheme = Self.loadBuiltInTheme(.claude)
    self.currentTheme = defaultTheme
    self.fileWatcher = ThemeFileWatcher()

    Task { await self.discoverThemes() }
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
    // Check cache first
    let cacheKey = fileURL.lastPathComponent
    if let cached = themeCache[cacheKey] {
      self.currentTheme = cached
      saveCurrentThemeSelection(cacheKey)
      return
    }

    // Parse and cache
    let yaml = try parser.parse(fileURL: fileURL)
    let runtime = RuntimeTheme(from: yaml)
    themeCache[cacheKey] = runtime
    self.currentTheme = runtime
    saveCurrentThemeSelection(cacheKey)

    // Setup hot-reload
    setupHotReload(for: fileURL)
  }

  public func loadBuiltInTheme(_ theme: AppTheme) {
    let runtime = Self.loadBuiltInTheme(theme)
    self.currentTheme = runtime
    saveCurrentThemeSelection(theme.rawValue)
  }

  private static func loadBuiltInTheme(_ theme: AppTheme) -> RuntimeTheme {
    let colors = getThemeColors(for: theme)
    return RuntimeTheme(appTheme: theme, colors: colors)
  }

  private static func getThemeColors(for theme: AppTheme) -> ThemeColors {
    // Reuse existing logic from Color+Extension.swift
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
      let primary = UserDefaults.standard.string(forKey: "customPrimaryHex") ?? "#7C3AED"
      let secondary = UserDefaults.standard.string(forKey: "customSecondaryHex") ?? "#FFB000"
      let tertiary = UserDefaults.standard.string(forKey: "customTertiaryHex") ?? "#64748B"
      return ThemeColors(
        brandPrimary: Color(hex: primary),
        brandSecondary: Color(hex: secondary),
        brandTertiary: Color(hex: tertiary)
      )
    }
  }

  // MARK: - Hot Reload

  private func setupHotReload(for fileURL: URL) {
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
  }

  // MARK: - Persistence

  private func saveCurrentThemeSelection(_ themeId: String) {
    UserDefaults.standard.set(themeId, forKey: "selectedTheme")
  }

  public func loadSavedTheme() async {
    let saved = UserDefaults.standard.string(forKey: "selectedTheme") ?? "claude"

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
}
