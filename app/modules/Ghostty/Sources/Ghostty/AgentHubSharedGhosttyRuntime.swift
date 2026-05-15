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
/// same `ghostty_app_t`, font cache, and config. Runtime creation remains
/// lazy; GhosttySwift's async factory keeps config loading off the main actor
/// before returning to the main actor for AppKit-facing runtime setup.
@MainActor
public enum AgentHubSharedGhosttyRuntime {
  private static var runtime: GhosttyRuntime?
  private static var loadingTask: Task<GhosttyRuntime, Error>?

  /// Returns the shared runtime, lazily constructing it the first time.
  /// Throws whatever GhosttySwift's runtime factory throws.
  public static func acquire() async throws -> GhosttyRuntime {
    if let runtime { return runtime }
    if let loadingTask {
      return try await loadingTask.value
    }

    AgentHubGhosttyRuntimeLogging.applyQuietDefault()
    let configPath = GhosttyConfigPathResolver.configuredPath()
    let task = Task { @MainActor in
      try await GhosttyRuntime.make(configPath: configPath)
    }
    loadingTask = task

    do {
      let new = try await task.value
      runtime = new
      loadingTask = nil
      return new
    } catch {
      loadingTask = nil
      throw error
    }
  }

  /// Warms the runtime. Safe to call multiple times.
  ///
  /// Config loading happens off the main actor, but the final Ghostty app
  /// creation remains main-actor work. Do not call it from launch or other
  /// latency-sensitive paths.
  /// Errors are swallowed — if pre-warm fails, the next `acquire()` call will
  /// surface the real error to the caller that needs it.
  public static func prewarm() {
    Task { @MainActor in
      _ = try? await acquire()
    }
  }
}
