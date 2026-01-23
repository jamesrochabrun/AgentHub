//  Color+Extension.swift
//  AgentHub
//
//  Created by James Rochabrun on 6/8/25.

import SwiftUI
import AppKit

// MARK: - Design Tokens

public enum DesignTokens {
  public enum Spacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 20
  }

  public enum Radius {
    public static let sm: CGFloat = 6
    public static let md: CGFloat = 10
    public static let lg: CGFloat = 14
  }

  public enum StatusSize {
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 10
  }

  public enum IconSize {
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 14
    public static let lg: CGFloat = 16
  }
}

/// Available app themes
public enum AppTheme: String, CaseIterable, Identifiable {
  case claude = "claude"
  case bat = "bat"
  case xcode = "Blue"
  case custom = "custom"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .claude: return "Claude"
    case .bat: return "Bat"
    case .xcode: return "Blue"
    case .custom: return "Custom"
    }
  }

  public var description: String {
    switch self {
    case .claude: return "Warm earth tones"
    case .bat: return "Purple with mustard accents"
    case .xcode: return "Cool blues"
    case .custom: return "User-defined colors"
    }
  }
}

/// Theme color definitions
public struct ThemeColors {
  public let brandPrimary: Color
  public let brandSecondary: Color
  public let brandTertiary: Color

  public init(brandPrimary: Color, brandSecondary: Color, brandTertiary: Color) {
    self.brandPrimary = brandPrimary
    self.brandSecondary = brandSecondary
    self.brandTertiary = brandTertiary
  }
}

extension Color {
  /// Create a Color from 0...255 RGB values (and optional alpha)
  init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
    self.init(.sRGB,
              red: red / 255.0,
              green: green / 255.0,
              blue: blue / 255.0,
              opacity: alpha)
  }

  init(red: Int, green: Int, blue: Int, alpha: Double = 1.0) {
    self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: alpha)
  }

  /// Create a Color from a hex string like "#CC785C" or "CC785C"
  init(hex: String, alpha: Double = 1.0) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int = UInt64()
    Scanner(string: hex).scanHexInt64(&int)

    let r, g, b: UInt64
    switch hex.count {
    case 6: // RGB (24-bit)
      (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
    default:
      (r, g, b) = (0, 0, 0)
    }

    self.init(red: Int(r), green: Int(g), blue: Int(b), alpha: alpha)
  }

  // MARK: - Named Colors (Legacy - use brand colors instead)

  static let bookCloth = Color(hex: "#CC785C")
  static let kraft = Color(hex: "#D4A27F")
  static let manilla = Color(hex: "#EBDBBC")

  // MARK: - Theme-Aware Brand Colors

  public static var brandPrimary: Color {
    getCurrentThemeColors().brandPrimary
  }

  public static var brandSecondary: Color {
    getCurrentThemeColors().brandSecondary
  }

  public static var brandTertiary: Color {
    getCurrentThemeColors().brandTertiary
  }

  // MARK: - Theme Colors Helper

  private static func getCurrentThemeColors() -> ThemeColors {
    let selectedTheme = UserDefaults.standard.string(forKey: "selectedTheme") ?? "claude"
    let theme = AppTheme(rawValue: selectedTheme) ?? .claude

    switch theme {
    case .claude:
      return ThemeColors(
        brandPrimary: Color(hex: "#CC785C"),   // bookCloth
        brandSecondary: Color(hex: "#D4A27F"), // kraft
        brandTertiary: Color(hex: "#EBDBBC")   // manilla
      )
    case .bat:
      // Bat: purple primary, real mustard secondary, slate tertiary
      return ThemeColors(
        brandPrimary: Color(hex: "#7C3AED"),   // deep purple
        brandSecondary: Color(hex: "#FFB000"), // mustard
        brandTertiary: Color(hex: "#64748B")  // slate gray
      )
    case .xcode:
      // Xcode: dynamic system colors inspired by Xcode syntax highlights
      // Use system variants to adapt to light/dark automatically
      return ThemeColors(
        brandPrimary: Color(nsColor: .systemBlue),
        brandSecondary: Color(nsColor: .systemIndigo),
        brandTertiary: Color(nsColor: .systemTeal)
      )
    case .custom:
      // Read user-defined custom palette from UserDefaults (hex strings)
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
  static let backgroundDark = Color(hex: "#262624")
  static let backgroundLight = Color(hex: "#FAF9F5")
  static let expandedContentBackgroundDark = Color(hex: "#1F2421")
  static let expandedContentBackgroundLight = Color.white//(hex: "#F8F4E3")

  // MARK: - Surface Colors (for depth hierarchy)

  public static var surfaceCanvas: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  public static var surfacePanel: Color {
    Color(nsColor: .controlBackgroundColor)
  }

  public static var surfaceCard: Color {
    Color(nsColor: .textBackgroundColor)
  }

  public static var surfaceStroke: Color {
    Color(nsColor: .separatorColor)
  }

  public static var surfaceElevated: Color {
    Color(nsColor: .controlBackgroundColor)
  }

  public static var surfaceOverlay: Color {
    Color.gray.opacity(0.06)
  }

  public static var surfaceHover: Color {
    Color.gray.opacity(0.10)
  }

  public static var borderSubtle: Color {
    Color.gray.opacity(0.12)
  }

  // MARK: - Theme-Aware Background Gradient

  public static var backgroundGradient: LinearGradient {
    LinearGradient(
      colors: [
        brandPrimary.opacity(0.08),
        brandSecondary.opacity(0.04),
        Color.clear
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  // MARK: - Adaptive Colors

  static func adaptiveBackground(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? backgroundDark : backgroundLight
  }

  static func adaptiveExpandedContentBackground(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? expandedContentBackgroundDark : expandedContentBackgroundLight
  }

}

// MARK: - Hex <-> NSColor Bridging
extension Color {
  /// Convert an NSColor to a hex string like #RRGGBB
  static func hexString(from nsColor: NSColor) -> String {
    let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
    let r = Int(round(color.redComponent * 255))
    let g = Int(round(color.greenComponent * 255))
    let b = Int(round(color.blueComponent * 255))
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}

extension NSColor {
  /// Create an NSColor from a hex string like #RRGGBB
  static func fromHex(_ hex: String) -> NSColor {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int = UInt64()
    Scanner(string: cleaned).scanHexInt64(&int)
    let r, g, b: UInt64
    switch cleaned.count {
    case 6:
      (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
    default:
      (r, g, b) = (124, 58, 237) // fallback purple
    }
    return NSColor(srgbRed: CGFloat(r) / 255.0,
                   green: CGFloat(g) / 255.0,
                   blue: CGFloat(b) / 255.0,
                   alpha: 1.0)
  }

  /// Hex string like #RRGGBB
  func toHexString() -> String {
    Color.hexString(from: self)
  }
}
