//
//  AgentHubGhosttyTerminalTabChrome.swift
//  AgentHub
//

import AgentHubCore
import SwiftUI

enum AgentHubGhosttyTerminalTabChrome {
  struct Style: Equatable {
    let stripBackground: NSColor
    let activeBackground: NSColor
    let hoverBackground: NSColor
    let closeHoverBackground: NSColor
    let divider: NSColor
    let tabEdge: NSColor

    var stripBackgroundColor: Color { Color(nsColor: stripBackground) }
    var activeBackgroundColor: Color { Color(nsColor: activeBackground) }
    var hoverBackgroundColor: Color { Color(nsColor: hoverBackground) }
    var closeHoverBackgroundColor: Color { Color(nsColor: closeHoverBackground) }
    var dividerColor: Color { Color(nsColor: divider) }
    var tabEdgeColor: Color { Color(nsColor: tabEdge) }

    static func == (lhs: Style, rhs: Style) -> Bool {
      AgentHubGhosttyTerminalTabChrome.signature(of: lhs.stripBackground)
        == AgentHubGhosttyTerminalTabChrome.signature(of: rhs.stripBackground)
        && AgentHubGhosttyTerminalTabChrome.signature(of: lhs.activeBackground)
        == AgentHubGhosttyTerminalTabChrome.signature(of: rhs.activeBackground)
        && AgentHubGhosttyTerminalTabChrome.signature(of: lhs.hoverBackground)
        == AgentHubGhosttyTerminalTabChrome.signature(of: rhs.hoverBackground)
        && AgentHubGhosttyTerminalTabChrome.signature(of: lhs.closeHoverBackground)
        == AgentHubGhosttyTerminalTabChrome.signature(of: rhs.closeHoverBackground)
        && AgentHubGhosttyTerminalTabChrome.signature(of: lhs.divider)
        == AgentHubGhosttyTerminalTabChrome.signature(of: rhs.divider)
        && AgentHubGhosttyTerminalTabChrome.signature(of: lhs.tabEdge)
        == AgentHubGhosttyTerminalTabChrome.signature(of: rhs.tabEdge)
    }
  }

  static let stripHeight: CGFloat = 32
  static let tabMinWidth: CGFloat = 118
  static let tabMaxWidth: CGFloat = 192
  static let firstTabCornerRadius: CGFloat = 10
  static let accent = Color.primary

  static let systemStyle = Style(
    stripBackground: NSColor.windowBackgroundColor.withAlphaComponent(0.78),
    activeBackground: NSColor.textBackgroundColor.withAlphaComponent(0.94),
    hoverBackground: NSColor.labelColor.withAlphaComponent(0.07),
    closeHoverBackground: NSColor.labelColor.withAlphaComponent(0.12),
    divider: NSColor.secondaryLabelColor.withAlphaComponent(0.18),
    tabEdge: NSColor.secondaryLabelColor.withAlphaComponent(0.13)
  )

  static func style(isDark: Bool, theme: RuntimeTheme?) -> Style {
    let background = isDark ? theme?.backgroundDark : theme?.backgroundLight
    guard let background else { return systemStyle }
    return style(baseBackground: NSColor(background), isDark: isDark)
  }

  static func style(baseBackground: NSColor, isDark: Bool) -> Style {
    let stripMix: CGFloat = isDark ? 0.18 : 0.08
    let activeMix: CGFloat = isDark ? 0.28 : 0.14
    let hoverMix: CGFloat = isDark ? 0.08 : 0.06
    let closeHoverMix: CGFloat = isDark ? 0.14 : 0.10
    let strokeMix: CGFloat = isDark ? 0.22 : 0.18
    let strokeColor = isDark ? NSColor.white : NSColor.black

    return Style(
      stripBackground: mix(baseBackground, with: .black, amount: stripMix),
      activeBackground: mix(baseBackground, with: .black, amount: activeMix),
      hoverBackground: mix(baseBackground, with: .white, amount: hoverMix),
      closeHoverBackground: mix(baseBackground, with: .white, amount: closeHoverMix),
      divider: mix(baseBackground, with: strokeColor, amount: strokeMix).withAlphaComponent(0.82),
      tabEdge: mix(baseBackground, with: strokeColor, amount: strokeMix).withAlphaComponent(0.64)
    )
  }

  static func hexString(from color: NSColor) -> String {
    let signature = signature(of: color)
    let red = signature.red
    let green = signature.green
    let blue = signature.blue
    return String(format: "#%02X%02X%02X", red, green, blue)
  }

  private static func mix(_ color: NSColor, with other: NSColor, amount: CGFloat) -> NSColor {
    let base = resolvedSRGBColor(color)
    let overlay = resolvedSRGBColor(other)
    let clampedAmount = min(max(amount, 0), 1)
    let baseAmount = 1 - clampedAmount
    return NSColor(
      srgbRed: (base.redComponent * baseAmount) + (overlay.redComponent * clampedAmount),
      green: (base.greenComponent * baseAmount) + (overlay.greenComponent * clampedAmount),
      blue: (base.blueComponent * baseAmount) + (overlay.blueComponent * clampedAmount),
      alpha: base.alphaComponent
    )
  }

  private static func resolvedSRGBColor(_ color: NSColor) -> NSColor {
    color.usingColorSpace(.sRGB) ?? color
  }

  private static func signature(of color: NSColor) -> (red: Int, green: Int, blue: Int, alpha: Int) {
    let resolved = resolvedSRGBColor(color)
    return (
      red: Int(round(resolved.redComponent * 255)),
      green: Int(round(resolved.greenComponent * 255)),
      blue: Int(round(resolved.blueComponent * 255)),
      alpha: Int(round(resolved.alphaComponent * 255))
    )
  }
}
