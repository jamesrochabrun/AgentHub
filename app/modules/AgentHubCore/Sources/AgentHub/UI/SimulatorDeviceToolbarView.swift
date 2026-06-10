//
//  SimulatorDeviceToolbarView.swift
//  AgentHub
//
//  Floating dark pill above the device chrome — device name + OS version and
//  the device-level actions (Home, Annotate), styled like a hardware remote
//  rather than panel chrome.
//

import SwiftUI

struct SimulatorDeviceToolbarView: View {
  let deviceName: String
  let runtimeName: String?
  let isInteractive: Bool
  let showsAnnotate: Bool
  let isAnnotating: Bool
  let isFetchingElements: Bool
  let onHome: () -> Void
  let onToggleAnnotate: () -> Void
  let onRefreshElements: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  /// Near-black in dark mode; white in light mode.
  private var pillColor: Color {
    colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : .white
  }

  /// Pill content (text/icons): white on the dark pill, near-black on the white
  /// pill.
  private var contentColor: Color {
    colorScheme == .dark ? .white : Color(white: 0.12)
  }

  /// Shadow inverts by mode: a soft white glow lifts the dark pill off the dark
  /// stage; a strong near-black drop shadow grounds the white pill in light mode.
  private var shadowColor: Color {
    colorScheme == .dark ? .white : .black
  }

  var body: some View {
    HStack(spacing: 4) {
      VStack(alignment: .leading, spacing: 1) {
        Text(deviceName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(contentColor)
          .lineLimit(1)
        if let runtimeName {
          Text(runtimeName)
            .font(.caption2)
            .foregroundStyle(contentColor.opacity(0.55))
            .lineLimit(1)
        }
      }
      .padding(.leading, 6)

      Spacer(minLength: 12)

      if isInteractive {
        toolbarButton(
          systemImage: "house",
          help: "Go to the Home Screen",
          action: onHome
        )
      }

      if showsAnnotate {
        toolbarButton(
          systemImage: "cursorarrow.and.square.on.square.dashed",
          help: isAnnotating
            ? "Stop annotating"
            : "Pick elements on the preview and send feedback to the agent",
          isActive: isAnnotating,
          action: onToggleAnnotate
        )

        if isAnnotating {
          if isFetchingElements {
            ProgressView()
              .controlSize(.small)
              .frame(width: 30, height: 30)
          } else {
            toolbarButton(
              systemImage: "arrow.clockwise",
              help: "Re-read the app's elements (after the UI changed)",
              action: onRefreshElements
            )
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Capsule(style: .continuous).fill(pillColor.opacity(colorScheme == .dark ? 0.97 : 1)))
    .overlay(
      Capsule(style: .continuous)
        .stroke(
          colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08),
          lineWidth: 1)
    )
    .clipShape(Capsule(style: .continuous))
    // Subtle white rim (dark mode, centered) / strong near-black drop shadow
    // (light mode, dropped downward).
    .shadow(
      color: shadowColor.opacity(colorScheme == .dark ? 0.16 : 0.38),
      radius: colorScheme == .dark ? 11 : 16,
      y: colorScheme == .dark ? 0 : 8)
    .shadow(
      color: shadowColor.opacity(colorScheme == .dark ? 0.1 : 0.28),
      radius: 5, y: colorScheme == .dark ? 0 : 3)
  }

  private func toolbarButton(
    systemImage: String,
    help: String,
    isActive: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .medium))
        // Active inverts against the pill: the fill takes the content color and
        // the glyph takes the pill color (legible on both dark and white pills).
        .foregroundStyle(isActive ? pillColor : contentColor.opacity(0.85))
        .frame(width: 30, height: 30)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isActive ? contentColor.opacity(0.92) : Color.white.opacity(0.001))
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}
