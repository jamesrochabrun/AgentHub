//
//  SimulatorDeviceChromeView.swift
//  AgentHub
//
//  Frames the live simulator stream like a physical device: the screen is
//  clipped to the device's continuous corner radius and floated inside a dark
//  bezel ring with a drop shadow, instead of filling the panel as a raw
//  rectangular framebuffer. The content is sized to the framebuffer's exact
//  aspect ratio, so input/annotation coordinate mapping inside it is
//  letterbox-free.
//

import SwiftUI

struct SimulatorDeviceChromeView<Content: View, TopAccessory: View>: View {
  /// Framebuffer size in pixels; `.zero` until the stream reports it.
  let contentPixelSize: CGSize
  /// CoreSimulator device type, used to look up the device's true display
  /// corner radius; unknown devices fall back to the aspect heuristic.
  var deviceTypeIdentifier: String? = nil
  @ViewBuilder let content: () -> Content
  /// Bar rendered above the device at the device's outer width (e.g. the
  /// floating device toolbar).
  @ViewBuilder let topAccessory: () -> TopAccessory

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.runtimeTheme) private var runtimeTheme

  /// The area behind the device follows the app's theme (same mechanism as the
  /// rest of the app's surfaces), so it tracks theme changes — not just system
  /// appearance. The bezel stays dark (a space-black device reads correctly on
  /// both light and dark stages).
  private var stageColor: Color {
    Color.adaptiveBackground(for: colorScheme, theme: runtimeTheme)
  }
  private static var bezelColor: Color { Color(red: 0.13, green: 0.13, blue: 0.145) }

  /// Like the toolbar pill: a soft white rim glow in dark mode, a gray drop
  /// shadow in light mode.
  private var shadowColor: Color {
    colorScheme == .dark ? .white : Color(white: 0.35)
  }

  /// Vertical space reserved for the accessory bar + gap in the fit math.
  private static var accessoryReserve: CGFloat { 56 }
  private static var accessoryGap: CGFloat { 10 }

  var body: some View {
    GeometryReader { geometry in
      let screen = screenRect(
        in: CGSize(
          width: geometry.size.width,
          height: max(geometry.size.height - Self.accessoryReserve, 1)))
      let radius = cornerRadius(for: screen)
      let bezel = Self.bezelWidth(for: screen)
      let deviceWidth = screen.width + bezel * 2

      VStack(spacing: Self.accessoryGap) {
        topAccessory()
          .frame(width: deviceWidth)

        ZStack {
          RoundedRectangle(cornerRadius: radius + bezel * 0.8, style: .continuous)
            .fill(Self.bezelColor)
            .overlay(
              RoundedRectangle(cornerRadius: radius + bezel * 0.8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .frame(width: deviceWidth, height: screen.height + bezel * 2)
            // White rim glow (dark) / gray drop shadow (light) — subtle, since
            // the device shape is large. Centered glow in dark, dropped in light.
            .shadow(
              color: shadowColor.opacity(colorScheme == .dark ? 0.16 : 0.28),
              radius: 28, y: colorScheme == .dark ? 0 : 14)
            .shadow(
              color: shadowColor.opacity(colorScheme == .dark ? 0.1 : 0.16),
              radius: 8, y: colorScheme == .dark ? 0 : 3)

          content()
            .frame(width: max(screen.width, 1), height: max(screen.height, 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
      }
      .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
    }
    .background(stageColor)
  }

  /// Aspect-fits the framebuffer into the available space with stage padding.
  /// Before the first frame reports a size, a modern-iPhone aspect placeholder
  /// keeps the view hierarchy (and the stream view inside it) stable.
  private func screenRect(in available: CGSize) -> CGRect {
    let pixelSize = (contentPixelSize.width > 0 && contentPixelSize.height > 0)
      ? contentPixelSize
      : CGSize(width: 402, height: 874)
    guard available.width > 0, available.height > 0 else { return .zero }
    let padding: CGFloat = 28
    let fitted = CGSize(
      width: max(available.width - padding * 2, 1),
      height: max(available.height - padding * 2, 1))
    let scale = min(fitted.width / pixelSize.width, fitted.height / pixelSize.height)
    return CGRect(
      x: 0, y: 0,
      width: pixelSize.width * scale,
      height: pixelSize.height * scale)
  }

  /// The device's true display corner radius (from `SimulatorDisplayMetrics`,
  /// in framebuffer pixels) scaled to view space; aspect heuristic otherwise.
  private func cornerRadius(for screen: CGRect) -> CGFloat {
    if let deviceTypeIdentifier,
      let radiusPixels = SimulatorDisplayMetrics.displayCornerRadiusPixels(
        deviceTypeIdentifier: deviceTypeIdentifier),
      contentPixelSize.width > 0, screen.width > 0 {
      return radiusPixels * (screen.width / contentPixelSize.width)
    }
    return Self.screenCornerRadius(for: screen)
  }

  /// Fallback when the device type is unknown. Face ID iPhones have a display
  /// corner radius of ~55 pt on a ~402 pt wide screen (≈13.5% of width);
  /// iPads round much less, and 16:9 home-button devices not at all.
  static func screenCornerRadius(for screen: CGRect) -> CGFloat {
    guard screen.width > 0 else { return 0 }
    let aspect = screen.height / screen.width
    if aspect > 1.9 || (aspect > 0 && aspect < 0.53) {
      // Modern edge-to-edge iPhone (portrait or landscape).
      return min(screen.width, screen.height) * 0.135
    }
    if aspect > 1.65 || (aspect > 0 && aspect < 0.61) {
      // 16:9 home-button iPhone: square screen.
      return 2
    }
    // iPad-ish.
    return min(screen.width, screen.height) * 0.025
  }

  static func bezelWidth(for screen: CGRect) -> CGFloat {
    max(8, min(screen.width, screen.height) * 0.028)
  }
}
