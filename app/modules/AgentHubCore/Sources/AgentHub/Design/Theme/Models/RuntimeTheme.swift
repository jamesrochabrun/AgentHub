//
//  RuntimeTheme.swift
//  AgentHub
//
//  Runtime theme with resolved colors
//

import AppKit
import SwiftUI

/// Runtime theme with resolved colors
public struct RuntimeTheme: Identifiable {
  public let id: String
  public let name: String
  public let isYAML: Bool
  public let isBuiltIn: Bool

  // Brand colors
  public let brandPrimary: Color
  public let brandSecondary: Color
  public let brandTertiary: Color

  // Background colors (optional)
  public let backgroundDark: Color?
  public let backgroundLight: Color?
  public let expandedContentBackgroundDark: Color?
  public let expandedContentBackgroundLight: Color?

  // Background gradient (optional)
  public let backgroundGradient: LinearGradient?

  // Terminal colors (optional — falls back to default dark/light if nil)
  public let terminalBackground: NSColor?
  public let terminalForeground: NSColor?
  public let terminalCursor: NSColor?
  public let terminalAnsiColors: [NSColor]?  // Exactly 16 if defined

  // Source file name for YAML themes (e.g., "sentry.yaml")
  public let sourceFileName: String?

  // Theme version from YAML (e.g., "1.0")
  public let version: String?

  /// Whether this theme provides custom background colors
  public var hasCustomBackgrounds: Bool {
    backgroundDark != nil || backgroundLight != nil
  }

  public init(from yaml: YAMLTheme, sourceFileName: String? = nil) {
    self.id = yaml.name
    self.name = yaml.name
    self.isYAML = true
    self.isBuiltIn = false
    self.sourceFileName = sourceFileName
    self.version = yaml.version

    // Resolve brand colors
    self.brandPrimary = Color(hex: yaml.colors.brand.primary)
    self.brandSecondary = Color(hex: yaml.colors.brand.secondary)
    self.brandTertiary = Color(hex: yaml.colors.brand.tertiary)

    // Resolve optional backgrounds
    if let bg = yaml.colors.backgrounds {
      self.backgroundDark = bg.dark.map { Color(hex: $0) }
      self.backgroundLight = bg.light.map { Color(hex: $0) }
      self.expandedContentBackgroundDark = bg.expandedContentDark.map { Color(hex: $0) }
      self.expandedContentBackgroundLight = bg.expandedContentLight.map { Color(hex: $0) }
    } else {
      self.backgroundDark = nil
      self.backgroundLight = nil
      self.expandedContentBackgroundDark = nil
      self.expandedContentBackgroundLight = nil
    }

    // Resolve terminal colors
    if let tc = yaml.colors.terminal {
      self.terminalBackground = tc.background.flatMap { NSColor(hex: $0) }
      self.terminalForeground = tc.foreground.flatMap { NSColor(hex: $0) }
      self.terminalCursor = tc.cursor.flatMap { NSColor(hex: $0) }
      if let ansi = tc.ansi {
        let colors: [NSColor?] = [
          ansi.black.flatMap { NSColor(hex: $0) },
          ansi.red.flatMap { NSColor(hex: $0) },
          ansi.green.flatMap { NSColor(hex: $0) },
          ansi.yellow.flatMap { NSColor(hex: $0) },
          ansi.blue.flatMap { NSColor(hex: $0) },
          ansi.magenta.flatMap { NSColor(hex: $0) },
          ansi.cyan.flatMap { NSColor(hex: $0) },
          ansi.white.flatMap { NSColor(hex: $0) },
          ansi.brightBlack.flatMap { NSColor(hex: $0) },
          ansi.brightRed.flatMap { NSColor(hex: $0) },
          ansi.brightGreen.flatMap { NSColor(hex: $0) },
          ansi.brightYellow.flatMap { NSColor(hex: $0) },
          ansi.brightBlue.flatMap { NSColor(hex: $0) },
          ansi.brightMagenta.flatMap { NSColor(hex: $0) },
          ansi.brightCyan.flatMap { NSColor(hex: $0) },
          ansi.brightWhite.flatMap { NSColor(hex: $0) },
        ]
        let resolved = colors.compactMap { $0 }
        self.terminalAnsiColors = resolved.count == 16 ? resolved : nil
      } else {
        self.terminalAnsiColors = nil
      }
    } else {
      self.terminalBackground = nil
      self.terminalForeground = nil
      self.terminalCursor = nil
      self.terminalAnsiColors = nil
    }

    // Resolve gradient
    if let gradient = yaml.colors.backgroundGradient, !gradient.isEmpty {
      let colors = gradient.map { Color(hex: $0.color).opacity($0.opacity) }
      self.backgroundGradient = LinearGradient(
        colors: colors,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    } else {
      self.backgroundGradient = nil
    }
  }

  // Constructor for built-in themes
  public init(appTheme: AppTheme, colors: ThemeColors) {
    self.id = appTheme.rawValue
    self.name = appTheme.displayName
    self.isYAML = false
    self.isBuiltIn = true
    self.sourceFileName = nil
    self.version = nil

    self.brandPrimary = colors.brandPrimary
    self.brandSecondary = colors.brandSecondary
    self.brandTertiary = colors.brandTertiary

    // Built-in themes use code-defined backgrounds and default terminal colors
    self.terminalBackground = nil
    self.terminalForeground = nil
    self.terminalCursor = nil
    self.terminalAnsiColors = nil
    self.backgroundDark = nil
    self.backgroundLight = nil
    self.expandedContentBackgroundDark = nil
    self.expandedContentBackgroundLight = nil
    self.backgroundGradient = nil
  }
}
