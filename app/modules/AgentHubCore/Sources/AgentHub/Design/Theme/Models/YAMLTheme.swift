//
//  YAMLTheme.swift
//  AgentHub
//
//  YAML theme definition for user-created themes
//

import Foundation

/// YAML theme definition
public struct YAMLTheme: Codable, Sendable {
  public let name: String
  public let version: String?
  public let author: String?
  public let description: String?
  public let colors: ThemeColors

  public struct ThemeColors: Codable, Sendable {
    public let brand: BrandColors
    public let backgrounds: BackgroundColors?
    public let backgroundGradient: [GradientStop]?
  }

  public struct BrandColors: Codable, Sendable {
    public let primary: String    // Hex color
    public let secondary: String
    public let tertiary: String
  }

  public struct BackgroundColors: Codable, Sendable {
    public let dark: String?
    public let light: String?
    public let expandedContentDark: String?
    public let expandedContentLight: String?
  }

  public struct GradientStop: Codable, Sendable {
    public let color: String
    public let opacity: Double
  }
}
