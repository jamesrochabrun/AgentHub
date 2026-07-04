//
//  TerminalAppearanceSync.swift
//  AgentHub
//
//  Pure skip/apply decision logic for embedded terminal appearance updates.
//  AppKit-free so it can be unit tested headlessly.
//

import Foundation

/// Decides whether a terminal appearance update actually needs to touch the
/// terminal views.
///
/// `EmbeddedTerminalView.updateNSView` calls `syncAppearance` on every SwiftUI
/// re-render, which happens many times per second while a session streams.
/// Reapplying an unchanged font is expensive (SwiftTerm rebuilds its font set,
/// recomputes cell dimensions, and relayouts) and reapplying unchanged colors
/// forces a full-view redraw via `needsDisplay`. The fingerprints below capture
/// the resolved inputs of each operation so redundant applications can be
/// skipped, while any real change — including a new terminal view joining the
/// workspace — still applies.
enum TerminalAppearanceSync {

  /// Everything that feeds `TerminalContainerView.updateFont`.
  ///
  /// Includes the identity set of the workspace tabs (one terminal view each)
  /// the font was applied to, so a newly opened tab or pane still receives the
  /// current font even when the requested family/size have not changed. Tab
  /// IDs are UUID-backed and never reused, unlike object identities.
  struct FontFingerprint: Equatable {
    let family: String
    let size: Double
    let surfaceIDs: Set<UUID>

    init(family: String, size: Double, surfaceIDs: Set<UUID>) {
      self.family = family
      self.size = size
      self.surfaceIDs = surfaceIDs
    }
  }

  /// Everything that feeds `TerminalContainerView.updateColors`.
  ///
  /// Keyed on *resolved color values* — never the theme id — because YAML
  /// themes hot-reload in place via `ThemeFileWatcher`: the id stays stable
  /// while `terminal.background` / `terminal.cursor` values change. Two themes
  /// that resolve to identical terminal colors are also correctly treated as
  /// equal.
  struct ColorFingerprint: Equatable {
    let isDark: Bool
    /// Resolved value of the theme's custom terminal background, if any.
    /// Normalized to nil in light mode, where theme terminal colors never apply.
    let themeBackground: String?
    /// Resolved value of the theme's custom terminal cursor, if any.
    /// Normalized to nil in light mode, where theme terminal colors never apply.
    let themeCursor: String?
    let surfaceIDs: Set<UUID>

    init(
      isDark: Bool,
      themeBackground: String?,
      themeCursor: String?,
      surfaceIDs: Set<UUID>
    ) {
      self.isDark = isDark
      // Theme terminal colors only apply in dark mode. Dropping them in light
      // mode keeps the fingerprint aligned with the effective output, so a
      // theme switch while in light mode does not force a redundant repaint.
      self.themeBackground = isDark ? themeBackground : nil
      self.themeCursor = isDark ? themeCursor : nil
      self.surfaceIDs = surfaceIDs
    }
  }

  /// Returns true when the incoming fingerprint differs from the last applied
  /// one. A nil `current` (nothing applied yet) always applies.
  static func shouldApply<Fingerprint: Equatable>(
    current: Fingerprint?,
    incoming: Fingerprint
  ) -> Bool {
    current != incoming
  }
}
