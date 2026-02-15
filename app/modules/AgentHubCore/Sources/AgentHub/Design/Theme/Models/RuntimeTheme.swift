//
//  RuntimeTheme.swift
//  AgentHub
//
//  Runtime theme with resolved colors
//

import SwiftUI

/// Runtime theme with resolved colors
@MainActor
public final class RuntimeTheme: ObservableObject, Identifiable, Sendable {
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

  public init(from yaml: YAMLTheme) {
    self.id = yaml.name
    self.name = yaml.name
    self.isYAML = true
    self.isBuiltIn = false

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

    self.brandPrimary = colors.brandPrimary
    self.brandSecondary = colors.brandSecondary
    self.brandTertiary = colors.brandTertiary

    // Built-in themes use code-defined backgrounds
    self.backgroundDark = nil
    self.backgroundLight = nil
    self.expandedContentBackgroundDark = nil
    self.expandedContentBackgroundLight = nil
    self.backgroundGradient = nil
  }
}
