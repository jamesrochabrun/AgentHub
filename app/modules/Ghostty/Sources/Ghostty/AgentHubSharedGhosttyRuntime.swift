//
//  AgentHubSharedGhosttyRuntime.swift
//  AgentHub
//

import Foundation
import GhosttySwift

/// Process-wide holder for a single `GhosttyRuntime`.
///
/// `TerminalSession.init` accepts an optional runtime; when none is passed it
/// constructs a fresh `GhosttyRuntime`, which internally calls
/// `ghostty_app_new` and loads fonts/themes/config from scratch. Doing that on
/// every embedded session adds ~1s of main-thread work per first-time mount
/// (observed in xctrace traces).
///
/// Sharing one runtime app-wide means every session past the first reuses the
/// same `ghostty_app_t`, font cache, and config — and the runtime can be
/// pre-warmed in the background once at launch so the first user-facing mount
/// is cheap too.
@MainActor
public enum AgentHubSharedGhosttyRuntime {
  private static var runtime: GhosttyRuntime?

  /// Returns the shared runtime, lazily constructing it the first time.
  /// Throws whatever `GhosttyRuntime.init` throws.
  public static func acquire() throws -> GhosttyRuntime {
    if let runtime { return runtime }
    AgentHubGhosttyRuntimeLogging.applyQuietDefault()
    let new = try GhosttyRuntime(configPath: GhosttyConfigPathResolver.configuredPath())
    runtime = new
    return new
  }

  /// Warms the runtime off the critical path. Safe to call multiple times.
  /// Errors are swallowed — if pre-warm fails, the next `acquire()` call will
  /// surface the real error to the caller that needs it.
  public static func prewarm() {
    _ = try? acquire()
  }
}
