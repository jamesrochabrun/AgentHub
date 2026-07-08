import Foundation

/// What the hot-reload pill shows. One value per (project, device) launch.
///
/// The contract is honesty: `.reloaded` only after the injection engine
/// confirms a hot-swap, `.rebuilding` whenever we fell back to a full
/// incremental rebuild, and `.unavailable` (with the reason) when the
/// machinery could not be set up at all — the pill never silently lies.
public enum HotReloadPhase: Equatable, Sendable {
  /// Hot reload is turned off for this panel.
  case disabled
  /// Support artifacts (injection + preview dylibs) are being prepared.
  case preparing(detail: String)
  /// Armed and watching for source changes.
  case idle
  /// A source file was saved; the engine is recompiling/injecting it.
  case reloading(fileName: String)
  /// The engine confirmed a hot-swap.
  case reloaded(summary: String)
  /// A change couldn't be hot-swapped — an incremental rebuild is running.
  case rebuilding(reason: String)
  /// Injection failed and the fallback rebuild also failed (or is off).
  case failed(message: String)
  /// Hot reload can't run for this launch (artifacts missing, app launched
  /// without injection, …).
  case unavailable(reason: String)
}

/// Events parsed from the injection engine's console output
/// (InjectionLite logs with a "🔥 " prefix on the app's stdout).
public enum HotReloadEngineEvent: Equatable, Sendable {
  /// The engine booted inside the app and started its file watcher.
  case engineReady
  /// The engine started recompiling a saved file.
  case recompiling(fileName: String)
  /// A hot-swap completed ("✅ Hot reload complete …").
  case injected(summary: String)
  /// The engine could not inject the change; a full rebuild is needed.
  case injectionFailed(message: String)
  /// Non-fatal engine diagnostics worth surfacing in the pill tooltip.
  case warning(message: String)
}

/// Startup status of the inserted preview host, parsed from its structured
/// console lines (`AGENTHUB_PREVIEW_HOST: …`). Distinguishes "still starting"
/// from real failures so the Previews tab can say what actually went wrong.
public enum PreviewHostStatus: Equatable, Sendable {
  /// No status line seen yet (host not inserted, or app still booting).
  case unknown
  /// The host is waiting for the app to become active before serving.
  case waitingForForeground
  /// The host's server is accepting connections on `port`.
  case listening(port: Int)
  /// The host could not start.
  case failed(reason: PreviewHostFailureReason, detail: String)
}

public enum PreviewHostFailureReason: Equatable, Sendable {
  /// Another process already owns the host's loopback port.
  case portInUse(port: Int)
  /// The server threw on startup for a non-port reason.
  case serverError
  /// The simulator runs an OS older than the previews floor (iOS 16).
  case unsupportedOSVersion
}

/// A classified change to the project's Swift sources, observed host-side.
public enum HotReloadSourceChange: Equatable, Sendable {
  /// An edit to an existing file — the injection engine can hot-swap it.
  case injectable(path: String)
  /// A structural change (file added/removed) that injection cannot
  /// represent — needs an incremental rebuild.
  case structural(path: String, kind: StructuralKind)

  public enum StructuralKind: String, Equatable, Sendable {
    case created
    case deleted
  }

  public var path: String {
    switch self {
    case .injectable(let path), .structural(let path, _):
      return path
    }
  }
}
